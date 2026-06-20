# Embedded Driver & HAL Patterns

<!-- SECTION: driver-structure -->
## Driver Structure

A peripheral driver exposes a minimal public API through its header file. The
implementation file owns all hardware-register access. Users of the driver call
the public functions and never touch registers directly:

```
components/drv_shtc3/
├── CMakeLists.txt
├── include/
│   └── drv_shtc3.h    # public API + opaque handle typedef
└── drv_shtc3.c        # register access, state machine, caching
```

Public header pattern:
```c
/* drv_shtc3.h */
#pragma once
#include "esp_err.h"

typedef struct drv_shtc3 *drv_shtc3_handle_t;  /* opaque handle */

esp_err_t drv_shtc3_init(int i2c_num, drv_shtc3_handle_t *out_handle);
esp_err_t drv_shtc3_read(drv_shtc3_handle_t handle, float *temp_c, float *rh_pct);
void      drv_shtc3_deinit(drv_shtc3_handle_t handle);
```

<!-- SECTION: hal-abstraction -->
## HAL Abstraction Layer

Wrap platform-specific calls behind a thin HAL so unit tests can substitute a
software implementation without flashing hardware:

```c
/* hal_i2c.h */
typedef esp_err_t (*hal_i2c_read_fn)(uint8_t addr, uint8_t *buf, size_t len, uint32_t timeout_ms);
typedef esp_err_t (*hal_i2c_write_fn)(uint8_t addr, const uint8_t *buf, size_t len, uint32_t timeout_ms);

typedef struct {
    hal_i2c_read_fn  read;
    hal_i2c_write_fn write;
} hal_i2c_t;

/* Production implementation */
esp_err_t hal_i2c_hw_read(uint8_t addr, uint8_t *buf, size_t len, uint32_t ms);
esp_err_t hal_i2c_hw_write(uint8_t addr, const uint8_t *buf, size_t len, uint32_t ms);

static const hal_i2c_t hal_i2c_hw = {
    .read  = hal_i2c_hw_read,
    .write = hal_i2c_hw_write,
};
```

<!-- SECTION: interrupt-safe -->
## Interrupt-Safe Data Transfer

Data shared between an ISR and a task must be transferred through a FreeRTOS
primitive — never via a plain global variable without `volatile` and atomic reads:

```c
/* Prefer a queue or semaphore over bare volatile globals */
static QueueHandle_t adc_queue;

void IRAM_ATTR adc_isr_handler(void *arg)
{
    uint16_t sample = adc_ll_get_raw_result(ADC_UNIT_1, ADC_CHANNEL_0);
    BaseType_t woken = pdFALSE;
    xQueueSendFromISR(adc_queue, &sample, &woken);
    portYIELD_FROM_ISR(woken);
}
```

Functions called from ISR context must be in IRAM — annotate with `IRAM_ATTR`:

```c
void IRAM_ATTR timer_isr(void *arg) { ... }
```

<!-- SECTION: power-management -->
## Power Management

Structure long-lived tasks to release CPU during waits — use `vTaskDelay` or
blocking primitives rather than busy-spin loops:

```c
/* BAD: busy spin burns CPU and prevents light sleep */
while (!data_ready) { /* spin */ }

/* GOOD: block on a semaphore; the scheduler can idle or enter light sleep */
xSemaphoreTake(data_ready_sem, portMAX_DELAY);
```

Acquire a power-management lock only during the critical section that requires
full clock speed:

```c
#include "esp_pm.h"

esp_pm_lock_handle_t pm_lock;
esp_pm_lock_create(ESP_PM_CPU_FREQ_MAX, 0, "uart_tx", &pm_lock);

esp_pm_lock_acquire(pm_lock);
uart_write_bytes(UART_NUM_0, buf, len);
esp_pm_lock_release(pm_lock);
```

<!-- SECTION: logging -->
## Logging Conventions

Use the `esp_log.h` tag system — one `TAG` constant per translation unit:

```c
static const char *TAG = "drv_shtc3";

ESP_LOGD(TAG, "raw = 0x%04X", raw);    /* DEBUG — verbose, stripped in release */
ESP_LOGI(TAG, "T=%.1f°C RH=%.1f%%", temp, rh);
ESP_LOGW(TAG, "CRC mismatch, retry %d", retry);
ESP_LOGE(TAG, "init failed: %s", esp_err_to_name(err));
```

Set the per-component log level in sdkconfig or at runtime:

```c
esp_log_level_set("drv_shtc3", ESP_LOG_DEBUG);  /* verbose during development */
esp_log_level_set("drv_shtc3", ESP_LOG_WARN);   /* quiet in production build */
```
