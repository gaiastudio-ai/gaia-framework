# FreeRTOS Task, Queue & Semaphore Patterns

<!-- SECTION: tasks -->
## Tasks

FreeRTOS tasks are independent threads. Size the stack based on the task's worst-
case frame depth — use `uxTaskGetStackHighWaterMark()` during development to tune:

```c
#define SENSOR_TASK_STACK  4096   /* bytes */
#define SENSOR_TASK_PRIO   5      /* 0 = idle, configMAX_PRIORITIES-1 = highest */

static void sensor_task(void *pvParameters)
{
    sensor_config_t *cfg = (sensor_config_t *)pvParameters;
    TickType_t last_wake = xTaskGetTickCount();

    for (;;) {
        float value;
        if (sensor_read(cfg->i2c_num, &value) == ESP_OK) {
            publish_reading(value);
        }
        /* Period-accurate loop — vTaskDelayUntil avoids drift */
        vTaskDelayUntil(&last_wake, pdMS_TO_TICKS(cfg->period_ms));
    }
}

/* Create from app_main or another task */
TaskHandle_t sensor_handle = NULL;
static sensor_config_t cfg = { .i2c_num = I2C_NUM_0, .period_ms = 500 };
xTaskCreate(sensor_task, "sensor", SENSOR_TASK_STACK, &cfg, SENSOR_TASK_PRIO, &sensor_handle);
```

<!-- SECTION: queues -->
## Queues

Use queues to transfer data between tasks without shared memory races:

```c
#include "freertos/queue.h"

typedef struct {
    float   value;
    int64_t timestamp_us;
} reading_t;

static QueueHandle_t reading_queue;

void readings_init(void)
{
    reading_queue = xQueueCreate(16, sizeof(reading_t));
    configASSERT(reading_queue != NULL);
}

/* Producer — called from sensor_task */
void publish_reading(float value)
{
    reading_t r = { .value = value, .timestamp_us = esp_timer_get_time() };
    if (xQueueSend(reading_queue, &r, pdMS_TO_TICKS(10)) != pdTRUE) {
        ESP_LOGW(TAG, "queue full — reading dropped");
    }
}

/* Consumer — called from upload_task */
void process_readings(void)
{
    reading_t r;
    while (xQueueReceive(reading_queue, &r, pdMS_TO_TICKS(100)) == pdTRUE) {
        upload_value(r.value, r.timestamp_us);
    }
}
```

<!-- SECTION: semaphores -->
## Semaphores & Mutexes

Use a mutex to protect shared resources accessed from multiple tasks. Prefer
`xSemaphoreCreateMutex()` over binary semaphores for mutual exclusion — mutexes
support priority inheritance on ESP-IDF:

```c
#include "freertos/semphr.h"

static SemaphoreHandle_t i2c_mutex;

void i2c_bus_init(void)
{
    i2c_mutex = xSemaphoreCreateMutex();
    configASSERT(i2c_mutex != NULL);
}

esp_err_t i2c_bus_read(uint8_t addr, uint8_t *buf, size_t len)
{
    if (xSemaphoreTake(i2c_mutex, pdMS_TO_TICKS(200)) != pdTRUE) {
        return ESP_ERR_TIMEOUT;
    }
    esp_err_t err = i2c_master_read_from_device(I2C_NUM_0, addr, buf, len,
                                                 pdMS_TO_TICKS(50));
    xSemaphoreGive(i2c_mutex);
    return err;
}
```

Binary semaphore for ISR → task synchronization:

```c
static SemaphoreHandle_t gpio_sem;

static void IRAM_ATTR gpio_isr_handler(void *arg)
{
    BaseType_t higher_priority_woken = pdFALSE;
    xSemaphoreGiveFromISR(gpio_sem, &higher_priority_woken);
    portYIELD_FROM_ISR(higher_priority_woken);
}

static void gpio_task(void *arg)
{
    for (;;) {
        xSemaphoreTake(gpio_sem, portMAX_DELAY);
        handle_gpio_event();
    }
}
```

<!-- SECTION: event-groups -->
## Event Groups

Coordinate multiple tasks with bitfield events:

```c
#include "freertos/event_groups.h"

#define WIFI_CONNECTED_BIT   BIT0
#define MQTT_READY_BIT       BIT1

static EventGroupHandle_t app_event_group;

void events_init(void) { app_event_group = xEventGroupCreate(); }

/* Set from wifi/mqtt init callbacks */
void on_wifi_connected(void)  { xEventGroupSetBits(app_event_group, WIFI_CONNECTED_BIT); }
void on_mqtt_connected(void)  { xEventGroupSetBits(app_event_group, MQTT_READY_BIT); }

/* Wait for both before uploading */
void upload_task(void *arg)
{
    xEventGroupWaitBits(app_event_group,
                        WIFI_CONNECTED_BIT | MQTT_READY_BIT,
                        pdFALSE, pdTRUE,  /* don't clear, wait for ALL */
                        portMAX_DELAY);
    /* Both bits set — safe to upload */
    for (;;) { process_readings(); }
}
```
