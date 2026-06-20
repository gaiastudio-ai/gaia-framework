# ESP-IDF Patterns & Component Structure

<!-- SECTION: component-layout -->
## Component Layout

ESP-IDF projects are organized around components. Each component is an
independent compilation unit with its own CMakeLists.txt:

```
project/
├── CMakeLists.txt              # top-level: project() + cmake_minimum_required()
├── sdkconfig                   # Kconfig-generated; commit this file
├── main/
│   ├── CMakeLists.txt          # idf_component_register(SRCS ...)
│   ├── main.c                  # app_main() entry point
│   └── Kconfig.projdefs        # project-level menuconfig options
└── components/
    └── my_sensor/
        ├── CMakeLists.txt      # idf_component_register(SRCS "sensor.c" INCLUDE_DIRS "include")
        ├── include/
        │   └── my_sensor.h
        └── sensor.c
```

Top-level CMakeLists.txt:
```cmake
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(my_project)
```

Component CMakeLists.txt:
```cmake
idf_component_register(
    SRCS "sensor.c"
    INCLUDE_DIRS "include"
    REQUIRES driver esp_log
)
```

<!-- SECTION: app-main -->
## app_main Entry Point

`app_main()` runs in the main task. Create application tasks from here; do not
block indefinitely inside `app_main` — return or loop with `vTaskDelay`.

```c
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "my_sensor.h"

static const char *TAG = "main";

void app_main(void)
{
    ESP_LOGI(TAG, "Firmware version: %s", CONFIG_APP_VERSION);
    my_sensor_init();
    /* Create application tasks */
    xTaskCreate(sensor_task, "sensor", 4096, NULL, 5, NULL);
    /* app_main returns; the scheduler keeps tasks alive */
}
```

<!-- SECTION: kconfig -->
## Kconfig Configuration

Expose compile-time options via Kconfig rather than #defines in source:

```kconfig
# components/my_sensor/Kconfig
menu "My Sensor Configuration"
    config SENSOR_SAMPLE_PERIOD_MS
        int "Sample period (ms)"
        default 1000
        range 100 60000
        help
            How often the sensor is sampled in milliseconds.

    config SENSOR_ENABLE_FILTER
        bool "Enable moving-average filter"
        default y
endmenu
```

In code:
```c
#define SAMPLE_MS  CONFIG_SENSOR_SAMPLE_PERIOD_MS
```

<!-- SECTION: nvs-patterns -->
## NVS (Non-Volatile Storage) Patterns

```c
#include "nvs_flash.h"
#include "nvs.h"

esp_err_t settings_init(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES ||
        err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    return err;
}

esp_err_t settings_save_threshold(int32_t val)
{
    nvs_handle_t h;
    ESP_ERROR_CHECK(nvs_open("storage", NVS_READWRITE, &h));
    esp_err_t err = nvs_set_i32(h, "threshold", val);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    return err;
}
```

<!-- SECTION: error-handling -->
## Error Handling

Use `ESP_ERROR_CHECK` for unrecoverable errors; check and propagate `esp_err_t`
for recoverable paths. Log the source with `ESP_LOGE`:

```c
esp_err_t sensor_read(float *out)
{
    esp_err_t err = i2c_master_read_from_device(I2C_NUM_0, ADDR, buf, 2, pdMS_TO_TICKS(50));
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "I2C read failed: %s", esp_err_to_name(err));
        return err;
    }
    *out = decode_value(buf);
    return ESP_OK;
}
```
