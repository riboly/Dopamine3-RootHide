#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <sys/param.h>
#include <sandbox.h>
#include <libjailbreak/jbclient_mach.h>

#include "dyld.h"
#include "dyld_jbinfo.h"

__attribute__((section("__DATA,__jbinfo"))) static char jbinfoSection[0x4000];
#define jbInfo ((struct dyld_jbinfo *)&jbinfoSection[0])

bool gDyldhookInitDone = false;

bool jbinfo_is_checked_in(void)
{
	return jbInfo->state == DYLD_STATE_CHECKED_IN;
}

char *jbinfo_get_jbroot(void)
{
	return jbInfo->jbRootPath;
}

bool jbinfo_should_force_cs_adhoc(void)
{
	return jbInfo->forceCSAdhoc;
}

void consume_tokenized_sandbox_extensions(char *sandboxExtensions)
{
	if (sandboxExtensions[0] == '\0') return;

	char *it = sandboxExtensions;
	char *last = sandboxExtensions;
	while (*(++it) != '\0') {
		if (*it == '|') {
			*it = '\0';
			sandbox_extension_consume(last);
			last = &it[1];
			*it = '|';
		}
	}
	sandbox_extension_consume(last);
}

void dyldhook_perform_checkin(void)
{
	struct jbserver_mach_msg_checkin_reply *replyPtr; // Only for sizeof macro

	char *jbRootPathPtr = &jbInfo->data[0];
	char *bootUUIDPtr = &jbInfo->data[sizeof(replyPtr->jbRootPath)];
	char *sandboxExtensionsPtr = &jbInfo->data[sizeof(replyPtr->jbRootPath)+sizeof(replyPtr->bootUUID)];

	// Tell jbserver (in launchd) that this process exists
	// This will, amongst other things, disable page validation, which allows instruction hooks to be applied later
	if (jbclient_mach_process_checkin(jbRootPathPtr, bootUUIDPtr, sandboxExtensionsPtr, &jbInfo->fullyDebugged, &jbInfo->forceCSAdhoc) == 0) {
		consume_tokenized_sandbox_extensions(sandboxExtensionsPtr);
		jbInfo->jbRootPath = jbRootPathPtr;
		jbInfo->bootUUID = bootUUIDPtr;
		jbInfo->sandboxExtensions = sandboxExtensionsPtr;
		jbInfo->state = DYLD_STATE_CHECKED_IN;
	}
}

mach_port_t mach_task_self_ = MACH_PORT_NULL;

static int simple_atoi(const char *value)
{
	bool negative = value[0] == '-';
	if (negative) value++;

	int result = 0;
	while (*value) {
		if (*value >= '0' && *value <= '9') {
			result = (result * 10) + (*value - '0');
		}
		value++;
	}
	return negative ? -result : result;
}

static void dyldhook_apply_requested_identity(uintptr_t argc, char **argv, char **envp)
{
	if (_simple_getenv(envp, "DYLD_HOOK_SETUID") == NULL) return;

	int uid = 0, gid = 0, ruid = 0, rgid = 0, fd = -1;
	gid_t groups[NGROUPS_MAX] = {0};
	for (int i = 1; i < argc; i++) {
		int remaining = (int)argc - i - 1;
		if (!strcmp(argv[i], "--fd")) {
			if (remaining < 1) break;
			fd = simple_atoi(argv[++i]);
		}
		else if (!strcmp(argv[i], "--uid")) {
			if (remaining < 1) break;
			uid = simple_atoi(argv[++i]);
		}
		else if (!strcmp(argv[i], "--ruid")) {
			if (remaining < 1) break;
			ruid = simple_atoi(argv[++i]);
		}
		else if (!strcmp(argv[i], "--gid")) {
			if (remaining < 1) break;
			gid = simple_atoi(argv[++i]);
		}
		else if (!strcmp(argv[i], "--rgid")) {
			if (remaining < 1) break;
			rgid = simple_atoi(argv[++i]);
		}
		else if (!strcmp(argv[i], "--groups")) {
			if (remaining < NGROUPS_MAX) break;
			for (int groupIndex = 0; groupIndex < NGROUPS_MAX; groupIndex++) {
				groups[groupIndex] = simple_atoi(argv[++i]);
			}
		}
	}
	if (fd < 0) return;

	setgid(gid);
	setgid(gid);
	setregid(rgid, -1);
	int groupCount = 0;
	while (groupCount < NGROUPS_MAX && groups[groupCount] != (gid_t)-1) groupCount++;
	setgroups(groupCount, groups);
	setuid(uid);
	setuid(uid);
	setreuid(ruid, -1);

	const uint8_t ready = 0x42;
	write(fd, &ready, sizeof(ready));
	__asm("b .");
}

void mach_init_4real(void)
{
	extern void mach_init(void);
	mach_init();

	mach_task_self_ = task_self_trap();
	mach_port_deallocate(mach_task_self_, mach_task_self_);
}

void dyldhook_init(uintptr_t kernelParams)
{
	mach_init_4real();

	extern void dyldhook_init_roothide(uintptr_t);
	dyldhook_init_roothide(kernelParams);


	// If we are in launchd, bail out
	if (getpid() == 1) {
		return;
	}

	// Walk kernelParams to get envp
	uintptr_t argc = *(uintptr_t *)(kernelParams + sizeof(void *));
	char **argv = (char **)(kernelParams + sizeof(void *) + sizeof(argc));
	char **envp = (char **)(kernelParams + sizeof(void *) + sizeof(argc) + (sizeof(const char *) * argc) + sizeof(void *));

	dyldhook_apply_requested_identity(argc, argv, envp);

	// If DYLD_INSERT_LIBRARIES is not set or does not contain systemhook, bail out
	const char *insertLibrariesVar = _simple_getenv(envp, "DYLD_INSERT_LIBRARIES");
	if (!insertLibrariesVar) return;
	if (!strstr(insertLibrariesVar, "/usr/lib/systemhook-") && !strstr(insertLibrariesVar, "/basebin/systemhook.dylib")) return;

	// If all is well, do check-in right here before dyld_start!
	dyldhook_perform_checkin();
}
