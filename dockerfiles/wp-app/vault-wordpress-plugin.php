<?php
/**
 * Plugin Name: Vault WordPress Plugin
 * Plugin URI: https://example.com/
 * Description: Automatically renew WordPress database credentials from Vault.
 * Version: 1.0.0
 * Author: Your Name
 * Author URI: https://example.com/
 */

defined('ABSPATH') || exit;

class VaultWordPressPlugin {
    private $vault_addr;
    private $role_id;
    private $secret_id;
    private $db_path;
    private $token_path;
    private $lease_path;

    public function __construct() {
        $this->vault_addr = getenv('VAULT_ADDR') ?: '';
        $this->role_id = getenv('VAULT_ROLE_ID') ?: '';
        $this->secret_id = getenv('VAULT_SECRET_ID') ?: '';
        $this->db_path = getenv('VAULT_DB_PATH') ?: 'database/creds/wp-app';
        $this->token_path = getenv('VAULT_TOKEN_PATH') ?: 'auth/approle/login';
        $this->lease_path = getenv('VAULT_LEASE_PATH') ?: 'sys/leases/lookup';
        $this->debug = getenv('VAULT_DEBUG') ?: true;

        add_action('plugins_loaded', array($this, 'renew_credentials'));
    }

    public function renew_credentials() {
        $token = $this->get_vault_token();
        if (!$token) {
            return;
        }

        $creds = $this->get_database_credentials($token);
        if (!$creds) {
            return;
        }

        $this->update_wordpress_config($creds);
    }

    private function get_vault_token() {
        $response = wp_remote_post($this->vault_addr . '/v1/' . $this->token_path, array(
            'body' => json_encode(array(
                'role_id' => $this->role_id,
                'secret_id' => $this->secret_id,
            )),
        ));

        if (is_wp_error($response)) {
            return false;
        }

        $body = wp_remote_retrieve_body($response);
        $data = json_decode($body, true);

        return isset($data['auth']['client_token']) ? $data['auth']['client_token'] : false;
    }

    private function get_database_credentials($token) {
        $response = wp_remote_post($this->vault_addr . '/v1/' . $this->db_path, array(
            'headers' => array(
                'X-Vault-Token' => $token,
            ),
        ));

        if (is_wp_error($response)) {
            return false;
        }

        $body = wp_remote_retrieve_body($response);
        $data = json_decode($body, true);

        return isset($data['data']) ? $data['data'] : false;
    }

    private function update_wordpress_config($creds) {
        $config_path = ABSPATH . 'wp-config.php';
        $config_content = file_get_contents($config_path);

        $config_content = preg_replace("/define\('DB_USER', '(.*)'\);/", "define('DB_USER', '{$creds['username']}');", $config_content);
        $config_content = preg_replace("/define\('DB_PASSWORD', '(.*)'\);/", "define('DB_PASSWORD', '{$creds['password']}');", $config_content);

        file_put_contents($config_path, $config_content);
    }
}

new VaultWordPressPlugin();