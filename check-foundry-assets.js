const https = require('https');
const fs = require('fs');

// Check release assets
const options = {
  hostname: 'api.github.com',
  path: '/repos/foundry-rs/foundry/releases/latest',
  headers: { 'User-Agent': 'Mozilla/5.0' }
};

https.get(options, (res) => {
  let data = '';
  res.on('data', chunk => data += chunk);
  res.on('end', () => {
    const release = JSON.parse(data);
    console.log('TAG:', release.tag_name);
    const zipAssets = release.assets.filter(a => a.name.includes('windows') && a.name.includes('zip'));
    console.log('WINDOWS_ZIP_ASSETS:');
    zipAssets.forEach(a => console.log('  ', a.name, a.browser_download_url, a.size));
    
    if (zipAssets.length > 0) {
      // Download the first matching asset
      const url = zipAssets[0].browser_download_url;
      const file = fs.createWriteStream('D:\\foundry.zip');
      https.get(url, (res2) => {
        res2.pipe(file);
        file.on('finish', () => {
          file.close();
          console.log('DOWNLOADED:', zipAssets[0].name, 'Size:', zipAssets[0].size);
        });
      }).on('error', (e) => console.log('ERR:', e.message));
    } else {
      console.log('NO_WINDOWS_ZIP_FOUND');
      // Check all assets
      console.log('ALL_ASSETS:');
      release.assets.forEach(a => console.log('  ', a.name));
    }
  });
}).on('error', (e) => console.log('ERR:', e.message));
