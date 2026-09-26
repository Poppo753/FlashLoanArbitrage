const https = require('https');
const fs = require('fs');
const zlib = require('zlib');

const url = 'https://github.com/foundry-rs/foundry/releases/download/v1.8.3/foundry-v1.8.3-x86_64-pc-windows-msvc.zip';
const file = fs.createWriteStream('D:\\foundry.zip');

https.get(url, (res) => {
  res.pipe(file);
  file.on('finish', () => {
    file.close();
    console.log('DOWNLOAD_DONE');
  });
}).on('error', (e) => {
  console.log('ERROR:', e.message);
});
