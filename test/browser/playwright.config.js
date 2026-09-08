const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: '.',
  use: { baseURL: 'http://127.0.0.1:8766', browserName: 'chromium' },
  webServer: {
    command: 'python3 -m http.server 8766 --bind 127.0.0.1 --directory ../../docs',
    url: 'http://127.0.0.1:8766',
    reuseExistingServer: false
  }
});
