/**
 * Copyright (c) 2024 Advanced Micro Devices, Inc. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * This file contains the sensors profile for the V80
 *
 * @file profile_sensors.h
 *
 */

#ifndef _PROFILES_SENSORS_H_
#define _PROFILES_SENSORS_H_

/******************************************************************************/
/* Includes                                                                   */
/******************************************************************************/

#include "profile_muxed_device.h"
#include "profile_pdr.h"

#include "asc_proxy_driver.h"
#include "ina3221.h"
#include "isl68221.h"
#include "cat34ts02.h"
#include "sys_mon.h"
#include "felix_sensors.h"


/******************************************************************************/
/* Defines                                                                    */
/******************************************************************************/

#define PROFILE_SENSORS_NUM_SENSORS ( 18 )


/******************************************************************************/
/* Local Function implementations                                             */
/******************************************************************************/

/**
 * @brief   Wrapper for the iSYS_MON_ReadTemperature function, to keep it the standard driver API format
 *
 * @param   unused1     Unused parameter (normally i2c bus)
 * @param   unused2     Unused parameter (normally i2c address)
 * @param   unused3     Unused parameter (normally i2c channel)
 * @param   pfValue     Pointer to latest sensor value
 *
 * @return  The return value of iSYS_MON_ReadTemperature
 *
 * @note    No sanity checks, etc, are done - this function is solely a wrapper API
 */
static inline int iSYS_MON_WrappedReadTemperature( uint8_t unused1, uint8_t unused2, uint8_t unused3, float *pfValue )
{
    return iSYS_MON_ReadTemperature( pfValue );
}

/**
 * @brief   Wrapper for the iAXC_GetTemperature function, to keep it the standard driver API format
 *
 * @param   unused1      Unused parameter (normally i2c bus)
 * @param   unused2      Unused parameter (normally i2c address)
 * @param   ucChannelNum Channel Num, used to specify QSFP ID
 * @param   pfValue      Pointer to latest sensor value
 *
 * @return  OK           Data retrieved from proxy driver successfully
 *          ERROR        Data not retrieved successfully
 *
 * @note    No sanity checks, etc, are done - this function is solely a wrapper API
 */
static inline int iAXC_WrappedGetTemperature( uint8_t unused1, uint8_t unused2, uint8_t ucChannelNum, float *pfValue )
{
    int iStatus = ERROR;

    if( 0 < MAX_NUM_EXTERNAL_DEVICES_AVAILABLE )
    {
        iStatus = iAXC_GetTemperature( ucChannelNum, pfValue );
    }

    return iStatus;
}

/**
 * @brief   Wrapper for the iSYS_MON_ReadVoltage function, to keep it the standard driver API format
 *
 * @param   unused1     Unused parameter (normally i2c bus)
 * @param   unused2     Unused parameter (normally i2c address)
 * @param   ucVType     Voltage type to read (normally i2c channel)
 * @param   pfValue     Pointer to latest sensor value
 *
 * @return  The return value of iSYS_MON_WrappedReadVoltage
 *
 * @note    No sanity checks, etc, are done - this function is solely a wrapper API
 */
static inline int iSYS_MON_WrappedReadVoltage( uint8_t unused1, uint8_t unused2, uint8_t ucVType, float *pfValue )
{
    return iSYS_MON_ReadVoltage( ucVType, pfValue );
}

/**
 * @brief   Function pointer called in profile to enable sensors that are used for V80 and V80P
 *
 * @return  TRUE to indictate sensor is enabled
 */
static inline int iSensorIsEnabled( void )
{
    return TRUE;
}

/**
 * @brief   Function pointer called in profile to disable sensors that are not used for V80P
 *
 * @return  TRUE if card is V80 or FALSE if card is V80P
 */
static inline int iSensorIsEnabledOrDisabled( void )
{
    static int     iSensorEnableStatus = FALSE;
    static uint8_t ucProductNameCheck  = FALSE;

    if( FALSE == ucProductNameCheck )
    {
        uint8_t pucField[ EEPROM_MAX_FIELD_SIZE ] =
        { 0 };
        uint8_t ucSizeBytes = 0;

        if( OK == iEEPROM_GetProductName( pucField, &ucSizeBytes ) )
        {
            if( ( NULL != strstr( ( char* )pucField, "v80" ) ) ||
                ( NULL != strstr( ( char* )pucField, "V80" ) ) )
            {
                if( ( NULL == strstr( ( char* )pucField, "80p" ) ) &&
                    ( NULL == strstr( ( char* )pucField, "80P" ) ) )
                {
                    /* Running on a v80 but not a v80p */
                    iSensorEnableStatus = TRUE;
                }
            }

            ucProductNameCheck = TRUE;
        }
    }

    return iSensorEnableStatus;
}


/******************************************************************************/
/* Public variables                                                           */
/******************************************************************************/

/*
 * FELIX sensor table. The first two rows (FPGA SYSMON) are AMD's V80 rows; the
 * board rows replace the V80 ones and use the read functions in felix_sensors.c.
 *
 * FELIX_ROW( name, id, types, total power, desc ids, read functions, readings ):
 *   the three lists are in ASC order { temperature, voltage, current, power },
 *   the desc id goes in ASC's "channel" field, the sensor address is unused (0).
 *   Readings: FELIX_RD_MILLI for mV/mA/mW values, FELIX_RD_NONE for unused slots.
 *   Temperature limits are warning / critical / fatal in degC (provisional values).
 *   Rows with total power TRUE are summed by AMD's ASDM into Total_Power (in mW);
 *   only 12V_INPUT is, so Total_Power is the board input power.
 *   The ami host driver reads only Total_Power, not the power of each row.
 */
#define FELIX_NO_CH  ASC_SENSOR_I2C_BUS_INVALID
#define FELIX_NO_LIM ASC_SENSOR_INVALID_VAL
#define FELIX_T      ASC_PROXY_DRIVER_SENSOR_BITFIELD_TEMPERATURE
#define FELIX_V      ASC_PROXY_DRIVER_SENSOR_BITFIELD_VOLTAGE
#define FELIX_I      ASC_PROXY_DRIVER_SENSOR_BITFIELD_CURRENT
#define FELIX_P      ASC_PROXY_DRIVER_SENSOR_BITFIELD_POWER
#define FELIX_RD( warn, crit, fatal, mod )                                                         \
    { 0, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, warn, crit, fatal, 0, 0, \
      ASC_PROXY_DRIVER_SENSOR_STATUS_NOT_PRESENT, ASC_PROXY_DRIVER_SENSOR_OPERATIONAL_STATUS_ENABLED, mod }
#define FELIX_RD_NONE  FELIX_RD( FELIX_NO_LIM, FELIX_NO_LIM, FELIX_NO_LIM, ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE )
#define FELIX_RD_MILLI FELIX_RD( FELIX_NO_LIM, FELIX_NO_LIM, FELIX_NO_LIM, ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_MILLI )
#define FELIX_RD_BOARD FELIX_RD( 85, 95, 105, ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE )
#define FELIX_RD_VR    FELIX_RD( 100, 110, 125, ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE )
#define FELIX_RD_DIMM  FELIX_RD( 80, 85, 95, ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE )
#define FELIX_LIST4( a, b, c, d ) { a, b, c, d }
#define FELIX_ROW( name, id, types, total, ch, fn, rd ) \
    { name, id, types, total, 0, ch, iSensorIsEnabled, fn, rd, ASC_PROXY_DRIVER_SENSOR_THRESHOLD_STATUS_HEALTHY }

ASC_PROXY_DRIVER_SENSOR_DATA PROFILE_SENSORS_SENSOR_DATA[ PROFILE_SENSORS_NUM_SENSORS ] =
{
    { "Device", DEVICE_DEVICE_ID, ASC_PROXY_DRIVER_SENSOR_BITFIELD_TEMPERATURE, FALSE, 0,
      { ASC_SENSOR_I2C_BUS_INVALID, ASC_SENSOR_I2C_BUS_INVALID, ASC_SENSOR_I2C_BUS_INVALID,
        ASC_SENSOR_I2C_BUS_INVALID }, iSensorIsEnabled,
      { iSYS_MON_WrappedReadTemperature, NULL, NULL, NULL },
      {
          { 0, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, DEVICE_TEMPERATURE_WARNING_HIGH,
            DEVICE_TEMPERATURE_CRITICAL_HIGH, DEVICE_TEMPERATURE_FATAL_HIGH, 0, 0,
            ASC_PROXY_DRIVER_SENSOR_STATUS_NOT_PRESENT,
            ASC_PROXY_DRIVER_SENSOR_OPERATIONAL_STATUS_ENABLED,  ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE },
          { 0, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL,
            ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, 0, 0, ASC_PROXY_DRIVER_SENSOR_STATUS_NOT_PRESENT,
            ASC_PROXY_DRIVER_SENSOR_OPERATIONAL_STATUS_ENABLED,  ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE },
          { 0, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL,
            ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, 0, 0, ASC_PROXY_DRIVER_SENSOR_STATUS_NOT_PRESENT,
            ASC_PROXY_DRIVER_SENSOR_OPERATIONAL_STATUS_ENABLED,  ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE },
          { 0, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL,
            ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, 0, 0, ASC_PROXY_DRIVER_SENSOR_STATUS_NOT_PRESENT,
            ASC_PROXY_DRIVER_SENSOR_OPERATIONAL_STATUS_ENABLED,  ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE } },
      ASC_PROXY_DRIVER_SENSOR_THRESHOLD_STATUS_HEALTHY
    },
    { "1V5_VCCAUX", VR_1V5_VCCAUX_DEVICE_ID, ASC_PROXY_DRIVER_SENSOR_BITFIELD_VOLTAGE, FALSE, 0,
      { ASC_SENSOR_I2C_BUS_INVALID, SYS_MON_VOLTAGES_VCCAUX, ASC_SENSOR_I2C_BUS_INVALID, ASC_SENSOR_I2C_BUS_INVALID },
      iSensorIsEnabled,
      { NULL, iSYS_MON_WrappedReadVoltage, NULL, NULL },
      {
          { 0, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL,
            ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, 0, 0, ASC_PROXY_DRIVER_SENSOR_STATUS_NOT_PRESENT,
            ASC_PROXY_DRIVER_SENSOR_OPERATIONAL_STATUS_ENABLED,  ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE },
          { 0, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL,
            ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, 0, 0, ASC_PROXY_DRIVER_SENSOR_STATUS_NOT_PRESENT,
            ASC_PROXY_DRIVER_SENSOR_OPERATIONAL_STATUS_ENABLED, ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_MILLI },
          { 0, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL,
            ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, 0, 0, ASC_PROXY_DRIVER_SENSOR_STATUS_NOT_PRESENT,
            ASC_PROXY_DRIVER_SENSOR_OPERATIONAL_STATUS_ENABLED,  ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE },
          { 0, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL,
            ASC_SENSOR_INVALID_VAL, ASC_SENSOR_INVALID_VAL, 0, 0, ASC_PROXY_DRIVER_SENSOR_STATUS_NOT_PRESENT,
            ASC_PROXY_DRIVER_SENSOR_OPERATIONAL_STATUS_ENABLED,  ASC_PROXY_DRIVER_SENSOR_UNIT_MOD_NONE } },
      ASC_PROXY_DRIVER_SENSOR_THRESHOLD_STATUS_HEALTHY
    },
    FELIX_ROW( "12V_INPUT", 50, FELIX_V | FELIX_I | FELIX_P, TRUE,
               FELIX_LIST4( FELIX_NO_CH, FELIX_ADM_12V, FELIX_INA_12V, FELIX_INA_12V ),
               FELIX_LIST4( NULL, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, iFELIX_INA226_ReadPower ),
               FELIX_LIST4( FELIX_RD_NONE, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_MILLI ) ),
    FELIX_ROW( "VCCINT", 51, FELIX_V | FELIX_I | FELIX_P, FALSE,
               FELIX_LIST4( FELIX_NO_CH, FELIX_ADM_VCCINT, FELIX_INA_VCCINT, FELIX_INA_VCCINT ),
               FELIX_LIST4( NULL, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, iFELIX_INA226_ReadPower ),
               FELIX_LIST4( FELIX_RD_NONE, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_MILLI ) ),
    FELIX_ROW( "VCCINT_VR", 52, FELIX_T | FELIX_I, FALSE,
               FELIX_LIST4( FELIX_LTM_VCCINT, FELIX_NO_CH, FELIX_LTM_VCCINT, FELIX_NO_CH ),
               FELIX_LIST4( iFELIX_LTM4700_ReadTemperature, NULL, iFELIX_LTM4700_ReadCurrent, NULL ),
               FELIX_LIST4( FELIX_RD_VR, FELIX_RD_NONE, FELIX_RD_MILLI, FELIX_RD_NONE ) ),
    FELIX_ROW( "VCC0V88", 53, FELIX_T | FELIX_V | FELIX_I, FALSE,
               FELIX_LIST4( FELIX_TMP_VCC0V88, FELIX_ADM_VCC0V88, FELIX_INA_VCC0V88, FELIX_NO_CH ),
               FELIX_LIST4( iFELIX_TMP435_ReadLocal, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, NULL ),
               FELIX_LIST4( FELIX_RD_BOARD, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_NONE ) ),
    FELIX_ROW( "MGTAVCC", 54, FELIX_T | FELIX_V | FELIX_I | FELIX_P, FALSE,
               FELIX_LIST4( FELIX_TMP_MGTAVCC, FELIX_ADM_MGTAVCC, FELIX_INA_MGTAVCC, FELIX_INA_MGTAVCC ),
               FELIX_LIST4( iFELIX_TMP435_ReadLocal, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, iFELIX_INA226_ReadPower ),
               FELIX_LIST4( FELIX_RD_BOARD, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_MILLI ) ),
    FELIX_ROW( "MGTAVTT", 55, FELIX_T | FELIX_V | FELIX_I | FELIX_P, FALSE,
               FELIX_LIST4( FELIX_TMP_MGTAVTT, FELIX_ADM_MGTAVTT, FELIX_INA_MGTAVTT, FELIX_INA_MGTAVTT ),
               FELIX_LIST4( iFELIX_TMP435_ReadLocal, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, iFELIX_INA226_ReadPower ),
               FELIX_LIST4( FELIX_RD_BOARD, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_MILLI ) ),
    FELIX_ROW( "MGTVCCAUX", 56, FELIX_V, FALSE,
               FELIX_LIST4( FELIX_NO_CH, FELIX_ADM_MGTVCCAUX, FELIX_NO_CH, FELIX_NO_CH ),
               FELIX_LIST4( NULL, iFELIX_ADM1266_ReadVoltage, NULL, NULL ),
               FELIX_LIST4( FELIX_RD_NONE, FELIX_RD_MILLI, FELIX_RD_NONE, FELIX_RD_NONE ) ),
    FELIX_ROW( "VCC1V2", 57, FELIX_T | FELIX_V | FELIX_I, FALSE,
               FELIX_LIST4( FELIX_TMP_VCC1V2, FELIX_ADM_VCC1V2, FELIX_INA_VCC1V2, FELIX_NO_CH ),
               FELIX_LIST4( iFELIX_TMP435_ReadLocal, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, NULL ),
               FELIX_LIST4( FELIX_RD_BOARD, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_NONE ) ),
    FELIX_ROW( "VCC1V5", 58, FELIX_T | FELIX_V | FELIX_I, FALSE,
               FELIX_LIST4( FELIX_TMP_VCC1V5, FELIX_ADM_VCC1V5, FELIX_INA_VCC1V5, FELIX_NO_CH ),
               FELIX_LIST4( iFELIX_TMP435_ReadLocal, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, NULL ),
               FELIX_LIST4( FELIX_RD_BOARD, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_NONE ) ),
    FELIX_ROW( "VCC1V8", 59, FELIX_T | FELIX_V | FELIX_I, FALSE,
               FELIX_LIST4( FELIX_TMP_VCC1V8, FELIX_ADM_VCC1V8, FELIX_INA_VCC1V8, FELIX_NO_CH ),
               FELIX_LIST4( iFELIX_TMP435_ReadLocal, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, NULL ),
               FELIX_LIST4( FELIX_RD_BOARD, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_NONE ) ),
    FELIX_ROW( "VCC2V5", 60, FELIX_V | FELIX_I, FALSE,
               FELIX_LIST4( FELIX_NO_CH, FELIX_ADM_VCC2V5, FELIX_INA_VCC2V5, FELIX_NO_CH ),
               FELIX_LIST4( NULL, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, NULL ),
               FELIX_LIST4( FELIX_RD_NONE, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_NONE ) ),
    FELIX_ROW( "VCC3V3", 61, FELIX_T | FELIX_V | FELIX_I, FALSE,
               FELIX_LIST4( FELIX_TMP_VCC3V3, FELIX_ADM_VCC3V3, FELIX_INA_VCC3V3, FELIX_NO_CH ),
               FELIX_LIST4( iFELIX_TMP435_ReadLocal, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, NULL ),
               FELIX_LIST4( FELIX_RD_BOARD, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_NONE ) ),
    FELIX_ROW( "VCC3V8", 62, FELIX_T | FELIX_V | FELIX_I, FALSE,
               FELIX_LIST4( FELIX_TMP_VCC2V5_3V8, FELIX_ADM_VCC3V8, FELIX_INA_VCC3V8, FELIX_NO_CH ),
               FELIX_LIST4( iFELIX_TMP435_ReadLocal, iFELIX_ADM1266_ReadVoltage, iFELIX_INA226_ReadCurrent, NULL ),
               FELIX_LIST4( FELIX_RD_BOARD, FELIX_RD_MILLI, FELIX_RD_MILLI, FELIX_RD_NONE ) ),
    FELIX_ROW( "VCC5V", 63, FELIX_V, FALSE,
               FELIX_LIST4( FELIX_NO_CH, FELIX_ADM_VCC5V, FELIX_NO_CH, FELIX_NO_CH ),
               FELIX_LIST4( NULL, iFELIX_ADM1266_ReadVoltage, NULL, NULL ),
               FELIX_LIST4( FELIX_RD_NONE, FELIX_RD_MILLI, FELIX_RD_NONE, FELIX_RD_NONE ) ),
    FELIX_ROW( "DDR4_VTT", 64, FELIX_V, FALSE,
               FELIX_LIST4( FELIX_NO_CH, FELIX_ADM_DDR4_VTT, FELIX_NO_CH, FELIX_NO_CH ),
               FELIX_LIST4( NULL, iFELIX_ADM1266_ReadVoltage, NULL, NULL ),
               FELIX_LIST4( FELIX_RD_NONE, FELIX_RD_MILLI, FELIX_RD_NONE, FELIX_RD_NONE ) ),
    FELIX_ROW( "DIMM", 65, FELIX_T, FALSE,
               FELIX_LIST4( FELIX_JC42_DIMM, FELIX_NO_CH, FELIX_NO_CH, FELIX_NO_CH ),
               FELIX_LIST4( iFELIX_JC42_ReadTemperature, NULL, NULL, NULL ),
               FELIX_LIST4( FELIX_RD_DIMM, FELIX_RD_NONE, FELIX_RD_NONE, FELIX_RD_NONE ) )
};

#endif
