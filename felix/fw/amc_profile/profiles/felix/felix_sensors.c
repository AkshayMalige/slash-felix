/*
 * FELIX FLX-155 board sensors for the AMC (SLASH mode).
 *
 * AMD's ASC proxy polls the table in profile_sensors.h every 100 ms. For each
 * reading it calls one of the functions below as fn( bus, 0, desc id, &value ).
 * The descriptor id picks an entry of xFelixDesc below (mux channel, I2C
 * address, PMBus page, INA226 shunt).
 *
 * All chips are behind the TCA9548 mux at 0x77 on PS I2C0 (PMC MIO 46/47).
 * The only I2C writes are the mux channel select and the PMBus PAGE command.
 *
 * Values are returned in mV, mA, mW and degC. ASC stores them as uint32 and the
 * unit modifier in profile_sensors.h tells the host which scale was used.
 */

#include <stddef.h>
#include <stdint.h>

#include "standard.h"
#include "pll.h"
#include "i2c.h"

#include "felix_sensors.h"

#define FELIX_SENSORS_NAME       "FELIX_SENSORS"

#define FELIX_MUX_ADDR           ( 0x77 )
#define FELIX_MUX_NONE           ( 0xFF )

#define FELIX_PMBUS_PAGE         ( 0x00 )
#define FELIX_PMBUS_VOUT_MODE    ( 0x20 )
#define FELIX_PMBUS_READ_VOUT    ( 0x8B )
#define FELIX_PMBUS_READ_IOUT    ( 0x8C )
#define FELIX_PMBUS_READ_TEMP1   ( 0x8D )
#define FELIX_LTM4700_PAGES      ( 2 )

#define FELIX_INA226_SHUNT       ( 0x01 )
#define FELIX_INA226_BUS         ( 0x02 )
#define FELIX_INA226_SHUNT_UV    ( 2.5f )
#define FELIX_INA226_BUS_MV      ( 1.25f )

#define FELIX_TMP435_LOCAL       ( 0x00 )
#define FELIX_TMP435_CONFIG1     ( 0x03 )
#define FELIX_TMP435_RANGE       ( 0x04 )
#define FELIX_TMP435_EXT_OFFSET  ( 64 )

#define FELIX_JC42_TEMP          ( 0x05 )

/* U77: TCA6416 IO expander with the board alert lines, only read for the boot log */
#define FELIX_U77_MUX_CH         ( 7 )
#define FELIX_U77_ADDR           ( 0x20 )

typedef struct FELIX_SENSOR_DESC
{
    uint8_t  ucMuxCh;
    uint8_t  ucAddr;
    uint8_t  ucPage;
    uint32_t ulShuntMicroOhm;

} FELIX_SENSOR_DESC;

/*
 * { mux channel, I2C address, PMBus page, shunt in micro-ohm (INA226 only) }
 * From the FLX155 schematic, checked with an I2C scan of the board.
 * ADM1266: one sequencer at 0x40, the page selects the rail.
 */
static const FELIX_SENSOR_DESC xFelixDesc[ FELIX_SENSOR_DESC_COUNT ] =
{
    [ FELIX_INA_12V ]        = { 2, 0x40, 0, 1500 },
    [ FELIX_INA_VCCINT ]     = { 2, 0x41, 0, 125 },
    [ FELIX_INA_MGTAVCC ]    = { 3, 0x42, 0, 1000 },
    [ FELIX_INA_MGTAVTT ]    = { 3, 0x43, 0, 1000 },
    [ FELIX_INA_VCC1V2 ]     = { 4, 0x44, 0, 1000 },
    [ FELIX_INA_VCC1V5 ]     = { 5, 0x45, 0, 1000 },
    [ FELIX_INA_VCC1V8 ]     = { 5, 0x46, 0, 1000 },
    [ FELIX_INA_VCC2V5 ]     = { 6, 0x47, 0, 1000 },
    [ FELIX_INA_VCC3V3 ]     = { 5, 0x48, 0, 1000 },
    [ FELIX_INA_VCC3V8 ]     = { 6, 0x49, 0, 1000 },
    [ FELIX_INA_VCC0V88 ]    = { 6, 0x4A, 0, 1000 },
    [ FELIX_TMP_MGTAVCC ]    = { 3, 0x48, 0, 0 },
    [ FELIX_TMP_MGTAVTT ]    = { 3, 0x49, 0, 0 },
    [ FELIX_TMP_VCC1V2 ]     = { 3, 0x4A, 0, 0 },
    [ FELIX_TMP_VCC1V5 ]     = { 5, 0x4B, 0, 0 },
    [ FELIX_TMP_VCC1V8 ]     = { 5, 0x4C, 0, 0 },
    [ FELIX_TMP_VCC3V3 ]     = { 5, 0x4D, 0, 0 },
    [ FELIX_TMP_VCC2V5_3V8 ] = { 6, 0x4E, 0, 0 },
    [ FELIX_TMP_VCC0V88 ]    = { 6, 0x4F, 0, 0 },
    [ FELIX_ADM_12V ]        = { 0, 0x40, 0, 0 },
    [ FELIX_ADM_VCCINT ]     = { 0, 0x40, 4, 0 },
    [ FELIX_ADM_VCC0V88 ]    = { 0, 0x40, 5, 0 },
    [ FELIX_ADM_MGTAVCC ]    = { 0, 0x40, 6, 0 },
    [ FELIX_ADM_MGTAVTT ]    = { 0, 0x40, 7, 0 },
    [ FELIX_ADM_VCC1V2 ]     = { 0, 0x40, 8, 0 },
    [ FELIX_ADM_MGTVCCAUX ]  = { 0, 0x40, 9, 0 },
    [ FELIX_ADM_VCC1V5 ]     = { 0, 0x40, 10, 0 },
    [ FELIX_ADM_VCC1V8 ]     = { 0, 0x40, 11, 0 },
    [ FELIX_ADM_VCC2V5 ]     = { 0, 0x40, 12, 0 },
    [ FELIX_ADM_VCC3V3 ]     = { 0, 0x40, 13, 0 },
    [ FELIX_ADM_VCC3V8 ]     = { 0, 0x40, 14, 0 },
    [ FELIX_ADM_VCC5V ]      = { 0, 0x40, 15, 0 },
    [ FELIX_ADM_DDR4_VTT ]   = { 0, 0x40, 16, 0 },
    [ FELIX_LTM_VCCINT ]     = { 1, 0x4E, 0, 0 },
    [ FELIX_JC42_DIMM ]      = { 7, 0x1B, 0, 0 },
};

/* Last selected mux channel. Cleared after any I2C error so the next read selects it again. */
static uint8_t ucFelixMuxCh = FELIX_MUX_NONE;
/* ADM1266 VOUT_MODE (exponent for READ_VOUT), read once per rail */
static uint8_t pucFelixVoutMode[ FELIX_SENSOR_DESC_COUNT ];
static uint8_t pucFelixVoutModeValid[ FELIX_SENSOR_DESC_COUNT ];
static int     iFelixBootLogDone = FALSE;

static int iFelixSelect( uint8_t ucBus, uint8_t ucMuxCh )
{
    uint8_t ucSel = ( uint8_t )( 1 << ucMuxCh );

    if( ucFelixMuxCh == ucMuxCh )
    {
        return OK;
    }
    if( OK != iI2C_Send( ucBus, FELIX_MUX_ADDR, &ucSel, 1 ) )
    {
        ucFelixMuxCh = FELIX_MUX_NONE;
        return ERROR;
    }
    ucFelixMuxCh = ucMuxCh;
    return OK;
}

static int iFelixReadReg( uint8_t ucBus, uint8_t ucMuxCh, uint8_t ucAddr, uint8_t ucReg, uint8_t *pucData, uint32_t ulLen )
{
    int iStatus = iFelixSelect( ucBus, ucMuxCh );

    if( OK == iStatus )
    {
        iStatus = iI2C_SendRecv( ucBus, ucAddr, &ucReg, 1, pucData, ulLen );
    }
    if( OK != iStatus )
    {
        ucFelixMuxCh = FELIX_MUX_NONE;
    }
    return iStatus;
}

static int iFelixSetPage( uint8_t ucBus, const FELIX_SENSOR_DESC *pxDesc, uint8_t ucPage )
{
    uint8_t pucCmd[ 2 ] = { FELIX_PMBUS_PAGE, ucPage };
    int     iStatus     = iFelixSelect( ucBus, pxDesc->ucMuxCh );

    if( OK == iStatus )
    {
        iStatus = iI2C_Send( ucBus, pxDesc->ucAddr, pucCmd, 2 );
    }
    if( OK != iStatus )
    {
        ucFelixMuxCh = FELIX_MUX_NONE;
    }
    return iStatus;
}

static float fFelixPow2( int32_t lExp )
{
    float fScale = 1.0f;

    while( lExp > 0 )
    {
        fScale *= 2.0f;
        lExp--;
    }
    while( lExp < 0 )
    {
        fScale /= 2.0f;
        lExp++;
    }
    return fScale;
}

/* PMBus LINEAR11: 5-bit signed exponent, 11-bit signed mantissa */
static float fFelixLinear11( uint16_t usWord )
{
    int32_t lExp  = ( usWord >> 11 ) & 0x1F;
    int32_t lMant = usWord & 0x7FF;

    if( lExp & 0x10 )
    {
        lExp -= 32;
    }
    if( lMant & 0x400 )
    {
        lMant -= 2048;
    }
    return ( float )lMant * fFelixPow2( lExp );
}

/* PMBus LINEAR16: unsigned mantissa, signed exponent in VOUT_MODE bits 4:0 */
static float fFelixLinear16( uint16_t usWord, uint8_t ucMode )
{
    int32_t lExp = ucMode & 0x1F;

    if( lExp & 0x10 )
    {
        lExp -= 32;
    }
    return ( float )usWord * fFelixPow2( lExp );
}

/* ASC keeps readings as uint32, so small negative readings (e.g. shunt offset at 0 A) become 0 */
static float fFelixNonNegative( float fValue )
{
    return ( fValue < 0.0f ) ? 0.0f : fValue;
}

/* Logs U77 direction and input registers once, at the first sensor read */
static void vFelixBootLog( uint8_t ucBus )
{
    uint8_t pucCfg[ 2 ] = { 0 };
    uint8_t pucIn[ 2 ]  = { 0 };
    int     iStatus     = OK;

    iFelixBootLogDone = TRUE;
    iStatus = iFelixReadReg( ucBus, FELIX_U77_MUX_CH, FELIX_U77_ADDR, 0x06, &pucCfg[ 0 ], 1 );
    if( OK == iStatus )
    {
        iStatus = iFelixReadReg( ucBus, FELIX_U77_MUX_CH, FELIX_U77_ADDR, 0x07, &pucCfg[ 1 ], 1 );
    }
    if( OK == iStatus )
    {
        iStatus = iFelixReadReg( ucBus, FELIX_U77_MUX_CH, FELIX_U77_ADDR, 0x00, &pucIn[ 0 ], 1 );
    }
    if( OK == iStatus )
    {
        iStatus = iFelixReadReg( ucBus, FELIX_U77_MUX_CH, FELIX_U77_ADDR, 0x01, &pucIn[ 1 ], 1 );
    }
    if( OK == iStatus )
    {
        PLL_LOG( FELIX_SENSORS_NAME, "U77 config %02x %02x inputs %02x %02x\r\n",
                 pucCfg[ 0 ], pucCfg[ 1 ], pucIn[ 0 ], pucIn[ 1 ] );
    }
    else
    {
        PLL_LOG( FELIX_SENSORS_NAME, "U77 read failed\r\n" );
    }
}

static const FELIX_SENSOR_DESC *pxFelixDesc( uint8_t ucBus, uint8_t ucDesc, float *pfValue )
{
    if( ( NULL == pfValue ) || ( FELIX_SENSOR_DESC_COUNT <= ucDesc ) )
    {
        return NULL;
    }
    if( FALSE == iFelixBootLogDone )
    {
        vFelixBootLog( ucBus );
    }
    return &xFelixDesc[ ucDesc ];
}

/* INA226 shunt voltage register, 2.5 uV/LSB: I [mA] = V [uV] * 1000 / R [uOhm] */
static int iFelixIna226Current( uint8_t ucBus, const FELIX_SENSOR_DESC *pxDesc, float *pfMilliAmps )
{
    uint8_t pucData[ 2 ] = { 0 };
    int16_t sRaw         = 0;

    if( OK != iFelixReadReg( ucBus, pxDesc->ucMuxCh, pxDesc->ucAddr, FELIX_INA226_SHUNT, pucData, 2 ) )
    {
        return ERROR;
    }
    sRaw         = ( int16_t )( ( pucData[ 0 ] << 8 ) | pucData[ 1 ] );
    *pfMilliAmps = fFelixNonNegative( ( float )sRaw * FELIX_INA226_SHUNT_UV * 1000.0f /
                                      ( float )pxDesc->ulShuntMicroOhm );
    return OK;
}

/* INA226 bus voltage register, 1.25 mV/LSB */
static int iFelixIna226BusVoltage( uint8_t ucBus, const FELIX_SENSOR_DESC *pxDesc, float *pfMilliVolts )
{
    uint8_t pucData[ 2 ] = { 0 };

    if( OK != iFelixReadReg( ucBus, pxDesc->ucMuxCh, pxDesc->ucAddr, FELIX_INA226_BUS, pucData, 2 ) )
    {
        return ERROR;
    }
    *pfMilliVolts = ( float )( ( pucData[ 0 ] << 8 ) | pucData[ 1 ] ) * FELIX_INA226_BUS_MV;
    return OK;
}

int iFELIX_INA226_ReadCurrent( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfMilliAmps )
{
    const FELIX_SENSOR_DESC *pxDesc = pxFelixDesc( ucBus, ucDesc, pfMilliAmps );

    if( NULL == pxDesc )
    {
        return ERROR;
    }
    return iFelixIna226Current( ucBus, pxDesc, pfMilliAmps );
}

/* Bus voltage x current. Must stay in mW: AMD's Total_Power adds these values and reports mW. */
int iFELIX_INA226_ReadPower( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfMilliWatts )
{
    const FELIX_SENSOR_DESC *pxDesc = pxFelixDesc( ucBus, ucDesc, pfMilliWatts );
    float                    fMilliAmps  = 0.0f;
    float                    fMilliVolts = 0.0f;

    if( ( NULL == pxDesc ) ||
        ( OK != iFelixIna226Current( ucBus, pxDesc, &fMilliAmps ) ) ||
        ( OK != iFelixIna226BusVoltage( ucBus, pxDesc, &fMilliVolts ) ) )
    {
        return ERROR;
    }
    *pfMilliWatts = fMilliVolts * fMilliAmps / 1000.0f;
    return OK;
}

/* TMP435 local (chip) temperature. The remote inputs read open circuit on this board and are not used.
   In extended range (CONFIG1 bit 2) the register is offset by 64. */
int iFELIX_TMP435_ReadLocal( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfDegC )
{
    const FELIX_SENSOR_DESC *pxDesc = pxFelixDesc( ucBus, ucDesc, pfDegC );
    uint8_t                  ucCfg  = 0;
    uint8_t                  ucTemp = 0;

    if( ( NULL == pxDesc ) ||
        ( OK != iFelixReadReg( ucBus, pxDesc->ucMuxCh, pxDesc->ucAddr, FELIX_TMP435_CONFIG1, &ucCfg, 1 ) ) ||
        ( OK != iFelixReadReg( ucBus, pxDesc->ucMuxCh, pxDesc->ucAddr, FELIX_TMP435_LOCAL, &ucTemp, 1 ) ) )
    {
        return ERROR;
    }
    *pfDegC = fFelixNonNegative( ( float )ucTemp - ( ( ucCfg & FELIX_TMP435_RANGE ) ? FELIX_TMP435_EXT_OFFSET : 0 ) );
    return OK;
}

/* ADM1266 rail voltage: PAGE selects the rail, READ_VOUT is LINEAR16 */
int iFELIX_ADM1266_ReadVoltage( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfMilliVolts )
{
    const FELIX_SENSOR_DESC *pxDesc       = pxFelixDesc( ucBus, ucDesc, pfMilliVolts );
    uint8_t                  pucData[ 2 ] = { 0 };

    if( ( NULL == pxDesc ) || ( OK != iFelixSetPage( ucBus, pxDesc, pxDesc->ucPage ) ) )
    {
        return ERROR;
    }
    if( FALSE == pucFelixVoutModeValid[ ucDesc ] )
    {
        if( OK != iFelixReadReg( ucBus, pxDesc->ucMuxCh, pxDesc->ucAddr, FELIX_PMBUS_VOUT_MODE,
                                 &pucFelixVoutMode[ ucDesc ], 1 ) )
        {
            return ERROR;
        }
        pucFelixVoutModeValid[ ucDesc ] = TRUE;
    }
    if( OK != iFelixReadReg( ucBus, pxDesc->ucMuxCh, pxDesc->ucAddr, FELIX_PMBUS_READ_VOUT, pucData, 2 ) )
    {
        return ERROR;
    }
    *pfMilliVolts = fFelixLinear16( ( uint16_t )( pucData[ 0 ] | ( pucData[ 1 ] << 8 ) ),
                                    pucFelixVoutMode[ ucDesc ] ) * 1000.0f;
    return OK;
}

/* LTM4700 VCCINT regulator, two phases (pages 0 and 1): current is the sum of both */
int iFELIX_LTM4700_ReadCurrent( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfMilliAmps )
{
    const FELIX_SENSOR_DESC *pxDesc       = pxFelixDesc( ucBus, ucDesc, pfMilliAmps );
    uint8_t                  pucData[ 2 ] = { 0 };
    float                    fAmps        = 0.0f;
    uint8_t                  ucPage       = 0;

    if( NULL == pxDesc )
    {
        return ERROR;
    }
    for( ucPage = 0; ucPage < FELIX_LTM4700_PAGES; ucPage++ )
    {
        if( ( OK != iFelixSetPage( ucBus, pxDesc, ucPage ) ) ||
            ( OK != iFelixReadReg( ucBus, pxDesc->ucMuxCh, pxDesc->ucAddr, FELIX_PMBUS_READ_IOUT, pucData, 2 ) ) )
        {
            return ERROR;
        }
        fAmps += fFelixLinear11( ( uint16_t )( pucData[ 0 ] | ( pucData[ 1 ] << 8 ) ) );
    }
    *pfMilliAmps = fFelixNonNegative( fAmps * 1000.0f );
    return OK;
}

/* LTM4700 temperature: the hotter of the two phases */
int iFELIX_LTM4700_ReadTemperature( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfDegC )
{
    const FELIX_SENSOR_DESC *pxDesc       = pxFelixDesc( ucBus, ucDesc, pfDegC );
    uint8_t                  pucData[ 2 ] = { 0 };
    float                    fMax         = 0.0f;
    float                    fTemp        = 0.0f;
    uint8_t                  ucPage       = 0;

    if( NULL == pxDesc )
    {
        return ERROR;
    }
    for( ucPage = 0; ucPage < FELIX_LTM4700_PAGES; ucPage++ )
    {
        if( ( OK != iFelixSetPage( ucBus, pxDesc, ucPage ) ) ||
            ( OK != iFelixReadReg( ucBus, pxDesc->ucMuxCh, pxDesc->ucAddr, FELIX_PMBUS_READ_TEMP1, pucData, 2 ) ) )
        {
            return ERROR;
        }
        fTemp = fFelixLinear11( ( uint16_t )( pucData[ 0 ] | ( pucData[ 1 ] << 8 ) ) );
        if( fTemp > fMax )
        {
            fMax = fTemp;
        }
    }
    *pfDegC = fMax;
    return OK;
}

/* DIMM thermal sensor (JC-42.4): 13-bit two's complement, 1/16 degC per LSB */
int iFELIX_JC42_ReadTemperature( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfDegC )
{
    const FELIX_SENSOR_DESC *pxDesc       = pxFelixDesc( ucBus, ucDesc, pfDegC );
    uint8_t                  pucData[ 2 ] = { 0 };
    uint16_t                 usWord       = 0;
    float                    fTemp        = 0.0f;

    if( ( NULL == pxDesc ) ||
        ( OK != iFelixReadReg( ucBus, pxDesc->ucMuxCh, pxDesc->ucAddr, FELIX_JC42_TEMP, pucData, 2 ) ) )
    {
        return ERROR;
    }
    usWord = ( uint16_t )( ( pucData[ 0 ] << 8 ) | pucData[ 1 ] );
    fTemp  = ( float )( usWord & 0x0FFF ) / 16.0f;
    if( usWord & 0x1000 )
    {
        fTemp -= 256.0f;
    }
    *pfDegC = fFelixNonNegative( fTemp );
    return OK;
}
