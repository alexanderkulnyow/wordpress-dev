<?php
/**
 * Plugin Name: WordPress Docker runtime
 * Description: Installation marker and scheduled WP-CLI diagnostics for the Docker image.
 */

// Managed by the wordpress-dev Docker image.
namespace WordPressDocker;

const DEFAULTS_PENDING = 'wordpress_docker_defaults_pending';
const DOCTOR_HOOK = 'wordpress_docker_doctor';
const DOCTOR_LAST_RUN = 'wordpress_docker_doctor_last_run';

add_action('wp_install', static function (): void {
    add_option(DEFAULTS_PENDING, '1', '', false);
});

function schedule_doctor(): void
{
    if (wp_next_scheduled(DOCTOR_HOOK) !== false) {
        return;
    }

    $now = current_datetime();
    $next = $now->setTime(3, 0);
    if ($next <= $now) {
        $next = $next->modify('+1 day');
    }

    $result = wp_schedule_event($next->getTimestamp(), 'daily', DOCTOR_HOOK, [], true);
    if (is_wp_error($result)) {
        throw new \RuntimeException($result->get_error_message());
    }
}

foreach (['timezone_string', 'gmt_offset'] as $option) {
    add_action('update_option_' . $option, static function (): void {
        wp_clear_scheduled_hook(DOCTOR_HOOK);
        schedule_doctor();
    });
}

add_action(DOCTOR_HOOK, static function (): void {
    $now = current_datetime();
    $log = @fopen(WP_CONTENT_DIR . '/wp-doctor.log', 'ab');
    if ($log === false) {
        error_log('WP Doctor: cannot open diagnostic log.');
        return;
    }

    if (!flock($log, LOCK_EX | LOCK_NB)) {
        fclose($log);
        return;
    }

    try {
        // Recalculate in the site's timezone so daylight-saving changes keep the run at 03:00.
        wp_clear_scheduled_hook(DOCTOR_HOOK);
        schedule_doctor();
        if (get_option(DOCTOR_LAST_RUN) === $now->format('Y-m-d')) {
            return;
        }

        update_option(DOCTOR_LAST_RUN, $now->format('Y-m-d'), false);
        fwrite($log, "\n[" . $now->format(DATE_ATOM) . "] wp doctor check --all: started\n");
        fflush($log);
        $command = [
            '/usr/local/bin/wp', 'doctor', 'check', '--all',
            '--config=/usr/local/share/wp-cli/doctor-command/doctor.yml',
            '--path=' . ABSPATH, '--allow-root', '--no-color',
        ];

        try {
            $process = proc_open($command, [
                0 => ['file', '/dev/null', 'r'],
                1 => $log,
                2 => $log,
            ], $pipes, ABSPATH);
            $exitCode = is_resource($process) ? proc_close($process) : 127;
        } catch (\Throwable $error) {
            fwrite($log, $error->getMessage() . "\n");
            $exitCode = 127;
        }

        fwrite($log, '[' . current_datetime()->format(DATE_ATOM) . '] exit_code=' . $exitCode . "\n");
    } finally {
        flock($log, LOCK_UN);
        fclose($log);
    }
});
