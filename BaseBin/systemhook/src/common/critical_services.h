#ifndef ROOTHIDE_CRITICAL_SERVICES_H
#define ROOTHIDE_CRITICAL_SERVICES_H

#include <stdbool.h>
#include <stddef.h>

bool roothide_critical_service_should_skip_injection(const char *path);
int roothide_critical_service_quarantine_from_watchdog(const char *panicMessage,
	char *pathOut, size_t pathOutSize);
int roothide_critical_service_quarantine_clear(void);
int roothide_critical_service_quarantine_copy(char *buffer, size_t bufferSize);

#endif
