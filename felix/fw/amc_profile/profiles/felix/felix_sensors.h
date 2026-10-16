#ifndef _FELIX_SENSORS_H_
#define _FELIX_SENSORS_H_

#include <stdint.h>

/*
 * FELIX FLX-155 sensor read functions for the AMC sensor table (profile_sensors.h).
 * Each id names one chip (and PMBus page) and is passed as the "channel" argument.
 * INA226 = rail current/voltage, TMP435 = board temperature next to a regulator,
 * ADM1266 = power sequencer rail voltages, LTM4700 = VCCINT regulator, JC42 = DIMM.
 */
typedef enum FELIX_SENSOR_DESC_ID
{
    FELIX_INA_12V = 0,
    FELIX_INA_VCCINT,
    FELIX_INA_MGTAVCC,
    FELIX_INA_MGTAVTT,
    FELIX_INA_VCC1V2,
    FELIX_INA_VCC1V5,
    FELIX_INA_VCC1V8,
    FELIX_INA_VCC2V5,
    FELIX_INA_VCC3V3,
    FELIX_INA_VCC3V8,
    FELIX_INA_VCC0V88,
    FELIX_TMP_MGTAVCC,
    FELIX_TMP_MGTAVTT,
    FELIX_TMP_VCC1V2,
    FELIX_TMP_VCC1V5,
    FELIX_TMP_VCC1V8,
    FELIX_TMP_VCC3V3,
    FELIX_TMP_VCC2V5_3V8,
    FELIX_TMP_VCC0V88,
    FELIX_ADM_12V,
    FELIX_ADM_VCCINT,
    FELIX_ADM_VCC0V88,
    FELIX_ADM_MGTAVCC,
    FELIX_ADM_MGTAVTT,
    FELIX_ADM_VCC1V2,
    FELIX_ADM_MGTVCCAUX,
    FELIX_ADM_VCC1V5,
    FELIX_ADM_VCC1V8,
    FELIX_ADM_VCC2V5,
    FELIX_ADM_VCC3V3,
    FELIX_ADM_VCC3V8,
    FELIX_ADM_VCC5V,
    FELIX_ADM_DDR4_VTT,
    FELIX_LTM_VCCINT,
    FELIX_JC42_DIMM,
    FELIX_SENSOR_DESC_COUNT

} FELIX_SENSOR_DESC_ID;

/* Arguments as ASC calls them: ( I2C bus, unused, FELIX_SENSOR_DESC_ID, result ) */
int iFELIX_INA226_ReadCurrent( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfMilliAmps );
int iFELIX_INA226_ReadPower( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfMilliWatts );
int iFELIX_TMP435_ReadLocal( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfDegC );
int iFELIX_ADM1266_ReadVoltage( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfMilliVolts );
int iFELIX_LTM4700_ReadCurrent( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfMilliAmps );
int iFELIX_LTM4700_ReadTemperature( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfDegC );
int iFELIX_JC42_ReadTemperature( uint8_t ucBus, uint8_t ucUnused, uint8_t ucDesc, float *pfDegC );

#endif
