# Embedded C/C++ Conventions

<!-- SECTION: naming -->
## Naming Conventions

| Entity | Convention | Example |
|---|---|---|
| Types (typedef struct/enum) | `snake_case_t` | `sensor_config_t` |
| Functions | `module_verb_noun()` | `i2c_bus_read()` |
| Constants / macros | `UPPER_SNAKE_CASE` | `MAX_RETRY_COUNT` |
| Global variables | `g_` prefix + snake_case | `g_event_group` |
| ISR functions | `IRAM_ATTR` + descriptive name | `gpio_isr_handler` |
| File-scope static variables | no prefix (static linkage is implicit) | `static bool initialized` |
| Opaque handle typedefs | `module_handle_t` (pointer to incomplete struct) | `sensor_handle_t` |

Avoid single-letter names outside tight loop counters. Avoid abbreviations that
are not immediately obvious to someone unfamiliar with the peripheral.

<!-- SECTION: header-guards -->
## Header Guards

Use `#pragma once` in all new C/C++ headers — it is universally supported by
modern toolchains (GCC, Clang, MSVC) and has no double-inclusion edge-cases:

```c
#pragma once    /* preferred over traditional include guards */

#include <stdint.h>
#include "esp_err.h"
```

Avoid:
```c
/* Fragile — symbol must be unique across the entire project */
#ifndef _MY_HEADER_H_
#define _MY_HEADER_H_
...
#endif
```

<!-- SECTION: fixed-width-types -->
## Fixed-Width Integer Types

Use `<stdint.h>` types for protocol fields and register maps — avoid `int`,
`long`, `unsigned` whose widths are architecture-dependent:

```c
/* Communication frame */
typedef struct __attribute__((packed)) {
    uint8_t  addr;
    uint16_t payload;   /* big-endian on wire */
    uint8_t  crc;
} can_frame_t;

/* Byte swap helpers for portability */
#include <sys/param.h>   /* htobe16 / be16toh — or use esp_rom_sys_* equivalents */
```

<!-- SECTION: assert-and-defensive -->
## Assertions & Defensive Checks

Use `configASSERT()` (FreeRTOS assertion) in task context for invariants that
represent programming errors, not runtime conditions. Do not use `assert()` in
ISR context or production release builds without a custom panic handler:

```c
void sensor_init(sensor_config_t *cfg)
{
    configASSERT(cfg != NULL);
    configASSERT(cfg->period_ms >= 10);
    /* ... */
}
```

Use `ESP_ERROR_CHECK()` only for errors that are truly unrecoverable. For paths
where recovery is possible, check the `esp_err_t` return value directly:

```c
/* Unrecoverable hardware init — panic + reboot is acceptable */
ESP_ERROR_CHECK(i2c_driver_install(I2C_NUM_0, I2C_MODE_MASTER, 0, 0, 0));

/* Recoverable — retry with backoff instead of crashing */
esp_err_t err = sensor_read(handle, &value);
if (err != ESP_OK) {
    ESP_LOGW(TAG, "read failed: %s — skipping sample", esp_err_to_name(err));
    return;
}
```

<!-- SECTION: cpp-in-c-projects -->
## C++ in ESP-IDF Projects

When mixing C and C++ translation units, guard C headers with `extern "C"`:

```c
/* my_driver.h — safe to include from both C and C++ */
#pragma once
#ifdef __cplusplus
extern "C" {
#endif

esp_err_t my_driver_init(void);

#ifdef __cplusplus
}
#endif
```

Prefer plain C for peripheral drivers — C++ class overhead (vtables, RTTI) is
rarely justified and complicates ISR placement. Reserve C++ for higher-level
application logic where RAII or templates genuinely reduce boilerplate.
