const https = require('https');
const fs = require('fs');

const url = 'https://github.com/foundry-rs/foundry/releases/download/v1.8.3/foundry_v1.8.3_win32_amd64.zip';
const file = fs.createWriteStream('D:\\foundry.zip');
let downloaded = 0;
const total = 48448906; // ~46MB

const req = https.get(url, (res) => {
  res.on('data', chunk => {
    downloaded += chunk.length;
    const pct = ((downloaded / total) * 100).toFixed(1);
    process.stdout.write(`\rDownloading: ${pct}% (${downloaded} / ${total} bytes)`);
  });
  res.pipe(file);
  file.on('finish', () => {
    file.close();
    console.log('\nDOWNLOAD_DONE');
    // Verify size
    const stats = fs.statSync('D:\\foundry.zip');
    console.log('FILE_SIZE:', stats.size, 'bytes');
  });
}).on('error', (e) => console.log('ERROR:', e.message));
