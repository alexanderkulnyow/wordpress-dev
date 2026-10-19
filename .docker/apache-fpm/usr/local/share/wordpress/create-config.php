<?php

$template = file_get_contents('/usr/local/share/wordpress/wp-config.php.template');
foreach (['AUTH_KEY', 'SECURE_AUTH_KEY', 'LOGGED_IN_KEY', 'NONCE_KEY', 'AUTH_SALT', 'SECURE_AUTH_SALT', 'LOGGED_IN_SALT', 'NONCE_SALT'] as $key) {
    $template = str_replace('__WORDPRESS_' . $key . '__', bin2hex(random_bytes(32)), $template);
}

$temporary = tempnam('/var/www/html', '.wp-config-');
if ($temporary === false || file_put_contents($temporary, $template) === false || !chmod($temporary, 0640) || !rename($temporary, '/var/www/html/wp-config.php')) {
    throw new RuntimeException('Cannot create wp-config.php.');
}
