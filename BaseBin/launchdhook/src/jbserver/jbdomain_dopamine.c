#include "jbserver_global.h"
#include "jbsettings.h"

#include <libjailbreak/codesign.h>
#include <libjailbreak/libjailbreak.h>
#include <libproc.h>
#include <errno.h>
#include <sys/param.h>

static char *read_file_to_string(const char *path) {
    FILE *fp = fopen(path, "rb");
    if (!fp) {
        return NULL;
    }

    if (fseek(fp, 0, SEEK_END) != 0) {
        fclose(fp);
        return NULL;
    }
    long size = ftell(fp);
    if (size < 0) {
        fclose(fp);
        return NULL;
    }
    rewind(fp);

    char *buffer = malloc((size_t)size + 1);
    if (!buffer) {
        fclose(fp);
        return NULL;
    }

    size_t read_bytes = fread(buffer, 1, (size_t)size, fp);
    fclose(fp);

    if (read_bytes != (size_t)size) {
        free(buffer);
        return NULL;
    }

    buffer[size] = '\0';
    return buffer;
}

bool dopamine_domain_allowed(audit_token_t clientToken)
{
	char path[PATH_MAX];
	if (proc_pidpath_audittoken(&clientToken, path, PATH_MAX) <= 0) return false;
	return is_dopamine_app(path);
}

bool dopamine_is_jailbroken(char **outVersion)
{
	*outVersion = read_file_to_string(JBROOT_PATH("/basebin/.version"));
	return true;
}

int dopamine_get_root(audit_token_t *processToken)
{
	pid_t pid = audit_token_to_pid(*processToken);
	uint64_t proc = proc_find(pid);
	if (!proc) return ESRCH;
	uint64_t ucred = proc_ucred(proc);
	if (!ucred) return EFAULT;

	if (kread32(ucred + koffsetof(ucred, uid)) == 501) {
		char procPath[4 * MAXPATHLEN] = {0};
		if (proc_pidpath(pid, procPath, sizeof(procPath)) <= 0) return ESRCH;
		gid_t groups[NGROUPS_MAX] = {0};
		if (kreadbuf(ucred + koffsetof(ucred, groups), groups, sizeof(groups)) != 0) return EIO;
		uid_t ruid = (uid_t)kread32(ucred + koffsetof(ucred, ruid));
		gid_t rgid = (gid_t)kread32(ucred + koffsetof(ucred, rgid));
		groups[0] = 0;
		const char *failureStage = NULL;
		int result = proc_ucred_update_content_with_stage(proc, procPath, 0, 0,
			ruid, rgid, groups, &failureStage);
		if (result != 0) {
			JBLogError("Dopamine get-root failed stage=%s pid=%d result=%d",
				failureStage ?: "ucred-update", pid, result);
			return result;
		}

		if (gSystemInfo.kernelStruct.proc_ro.exists) {
			uint64_t proc_ro = kread_ptr(proc + koffsetof(proc, proc_ro));

			if (koffsetof(proc_ro, task_tokens)) {
				uint64_t auditToken = proc_ro + koffsetof(proc_ro, task_tokens) + koffsetof(task_token_ro_data, audit_token);
				kwrite32(auditToken + 4, 0); // uid
				kwrite32(auditToken + 8, 0); // gid
			}
		}

		return 0;
	}

	return 1;
}

int dopamine_drop_root(audit_token_t *processToken)
{
	pid_t pid = audit_token_to_pid(*processToken);
	uint64_t proc = proc_find(pid);
	if (!proc) return ESRCH;
	uint64_t ucred = proc_ucred(proc);
	if (!ucred) return EFAULT;

	if (kread32(ucred + koffsetof(ucred, uid)) == 0) {
		char procPath[4 * MAXPATHLEN] = {0};
		if (proc_pidpath(pid, procPath, sizeof(procPath)) <= 0) return ESRCH;
		gid_t groups[NGROUPS_MAX] = {0};
		if (kreadbuf(ucred + koffsetof(ucred, groups), groups, sizeof(groups)) != 0) return EIO;
		uid_t ruid = (uid_t)kread32(ucred + koffsetof(ucred, ruid));
		gid_t rgid = (gid_t)kread32(ucred + koffsetof(ucred, rgid));
		groups[0] = 501;
		const char *failureStage = NULL;
		int result = proc_ucred_update_content_with_stage(proc, procPath, 501, 501,
			ruid, rgid, groups, &failureStage);
		if (result != 0) {
			JBLogError("Dopamine drop-root failed stage=%s pid=%d result=%d",
				failureStage ?: "ucred-update", pid, result);
			return result;
		}

		if (gSystemInfo.kernelStruct.proc_ro.exists) {
			uint64_t proc_ro = kread_ptr(proc + koffsetof(proc, proc_ro));

			if (koffsetof(proc_ro, task_tokens)) {
				uint64_t auditToken = proc_ro + koffsetof(proc_ro, task_tokens) + koffsetof(task_token_ro_data, audit_token);
				kwrite32(auditToken + 4, 501); // uid
				kwrite32(auditToken + 8, 501); // gid
			}
		}

		return 0;
	}

	return 1;
}

struct jbserver_domain gDopamineDomain = {
	.permissionHandler = dopamine_domain_allowed,
	.actions = {
		// JBS_DOPAMINE_IS_JAILBROKEN
		{
			.handler = dopamine_is_jailbroken,
			.args = (jbserver_arg[]){
				{ .name = "version", .type = JBS_TYPE_STRING, .out = true },
				{ 0 },
			},
		},
		// JBS_DOPAMINE_GET_ROOT
		{
			.handler = dopamine_get_root,
			.args = (jbserver_arg[]){
				{ .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
				{ 0 },
			},
		},
		// JBS_DOPAMINE_DROP_ROOT
		{
			.handler = dopamine_drop_root,
			.args = (jbserver_arg[]){
				{ .name = "caller-token", .type = JBS_TYPE_CALLER_TOKEN, .out = false },
				{ 0 },
			},
		},
		{ 0 },
	},
};
