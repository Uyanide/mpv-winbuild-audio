/*
 * Minimal libmpv consumer, cross-compiled and run under wine by verify.sh.
 *
 * It exists to prove two things the static import-table checks cannot:
 *   1. the DLL actually loads on a machine with no GPU driver -- wine has no
 *      vulkan-1.dll either, which is precisely the CI failure this build fixes;
 *   2. the FFmpeg whitelist really covers every container/codec we ship for,
 *      because a missing decoder shows up here and nowhere in the build log.
 *
 * Usage: smoke.exe <audiofile>...   -- exits non-zero if any file fails.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <mpv/client.h>

static void set_opt(mpv_handle *ctx, const char *name, const char *val)
{
    /* Best effort: some of these are tuning knobs that may not exist in every
       mpv release, and none of them is worth failing the smoke test over. */
    mpv_set_option_string(ctx, name, val);
}

static int play(const char *path)
{
    int rc = 1;
    char *codec = NULL;
    mpv_handle *ctx = mpv_create();

    if (!ctx) {
        fprintf(stderr, "FAIL %s: mpv_create() returned NULL\n", path);
        return 1;
    }

    set_opt(ctx, "terminal", "no");
    set_opt(ctx, "vo", "null");
    set_opt(ctx, "ao", "null");
    set_opt(ctx, "ao-null-untimed", "yes");
    set_opt(ctx, "untimed", "yes");
    set_opt(ctx, "audio-display", "no");
    set_opt(ctx, "config", "no");
    set_opt(ctx, "load-scripts", "no");

    int err = mpv_initialize(ctx);
    if (err < 0) {
        fprintf(stderr, "FAIL %s: mpv_initialize: %s\n", path, mpv_error_string(err));
        goto out;
    }

    const char *cmd[] = { "loadfile", path, NULL };
    err = mpv_command(ctx, cmd);
    if (err < 0) {
        fprintf(stderr, "FAIL %s: loadfile: %s\n", path, mpv_error_string(err));
        goto out;
    }

    for (;;) {
        mpv_event *ev = mpv_wait_event(ctx, 30.0);

        if (ev->event_id == MPV_EVENT_NONE) {
            fprintf(stderr, "FAIL %s: timed out waiting for playback to end\n", path);
            goto out;
        }
        if (ev->event_id == MPV_EVENT_SHUTDOWN) {
            fprintf(stderr, "FAIL %s: unexpected shutdown\n", path);
            goto out;
        }
        if (ev->event_id == MPV_EVENT_FILE_LOADED && !codec) {
            char *v = NULL;
            if (mpv_get_property(ctx, "audio-codec-name", MPV_FORMAT_STRING, &v) >= 0 && v)
                codec = v;
        }
        if (ev->event_id == MPV_EVENT_END_FILE) {
            mpv_event_end_file *ef = ev->data;
            if (ef->reason == MPV_END_FILE_REASON_ERROR) {
                fprintf(stderr, "FAIL %s: end-file error: %s\n", path,
                        mpv_error_string(ef->error));
                goto out;
            }
            if (ef->reason != MPV_END_FILE_REASON_EOF) {
                fprintf(stderr, "FAIL %s: ended with reason %d, expected EOF\n",
                        path, (int)ef->reason);
                goto out;
            }
            break;
        }
    }

    /* An empty codec name means mpv opened the container but decoded nothing,
       which is exactly how a missing entry in the decoder whitelist presents. */
    if (!codec || !codec[0]) {
        fprintf(stderr, "FAIL %s: no audio-codec-name was ever reported\n", path);
        goto out;
    }

    printf("PASS %-14s %s\n", codec, path);
    rc = 0;

out:
    if (codec)
        mpv_free(codec);
    mpv_terminate_destroy(ctx);
    return rc;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <audiofile>...\n", argv[0]);
        return 2;
    }

    unsigned long ver = mpv_client_api_version();
    printf("libmpv client API %lu.%lu\n", ver >> 16, ver & 0xffff);

    int failed = 0;
    for (int i = 1; i < argc; i++)
        failed += play(argv[i]);

    if (failed) {
        fprintf(stderr, "\n%d of %d file(s) failed\n", failed, argc - 1);
        return 1;
    }
    printf("\nall %d file(s) played\n", argc - 1);
    return 0;
}
