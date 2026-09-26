const https = require('https');
const fs = require('fs');
const { URL } = require('url');

const downloadUrl = 'https://github.com/foundry-rs/foundry/releases/download/v1.8.3/foundry_v1.8.3_win32_amd64.zip';
const outputPath = 'D:\\foundry.zip';

const file = fs.createWriteStream(outputPath);

const req = https.get(downloadUrl, { followRedirects: true, maxRedirects: 5 }, (res) => {
  console.log('STATUS:', res.statusCode);
  console.log('CONTENT-TYPE:', res.headers['content-type']);
  console.log('CONTENT-LENGTH:', res.headers['content-length']);
  console.log('LOCATION:', res.headers.location || 'N/A');
  
  res.pipe(file);
  let totalBytes = 0;
  res.on('data', chunk => totalBytes += chunk.length);
  file.on('finish', () => {
    file.close();
    const stats = fs.statSync(outputPath);
    console.log('DOWNLOADED_BYTES:', stats.size);
    if (stats.size === 0) {
      console.log('ERROR: File is empty - likely a redirect or error page');
      // Read the content to see what happened
      const content = fs.readFileSync(outputPath, 'utf8');
      console.log('CONTENT_PREVIEW:', content.substring(0, 200));
    }
  });
}).on('error', (e) => {
  console.log('ERROR:', e.message);
});

req.setTimeout(30000, () => {
  console.log('TIMEOUT');
  req.destroy();
});
