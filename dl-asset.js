const https = require('https');
const fs = require('fs');

// Use the direct redirect URL from GitHub
const url = 'https://release-assets.githubusercontent.com/github-production-release-asset/404320053/42fa7b6e-6f35-412c-b09e-41c63dbbb15b?sp=r&sv=2018-11-09&sr=b&spr=https&se=2026-09-26T02%3A48%3A41Z&rscd=attachment%3B+filename%3Dfoundry_v1.8.3_win32_amd64.zip&rsct=application%2Foctet-stream&skoid=96c2d410-5711-43a1-aedd-ab1947aa7ab0&sktid=398a6654-997b-47e9-b12b-9515b896b4de&skt=2026-09-26T01%3A48%3A18Z&ske=2026-09-26T02%3A48%3A41Z&sks=b&skv=2018-11-09&sig=CS3Zkh1ZgAnaU2ll3c0tDlpUff0Bydgpk%2F5gMPvEhXY%3D&jwt=eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiJnaXRodWIuY29tIiwiYXVkIjoicmVsZWFzZS1hc3NldHMuZ2l0aHVidXNlcmNvbnRlbnQuY29tIiwia2V5Ijoia2V5MSIsImV4cCI6MTc5MDM5MTg4NSwibmJmIjoxNzkwMzg4Mjg1LCJwYXRoIjoicmVsZWFzZWFzc2V0cHJvZHVjdGlvbi5ibG9iLmNvcmUud2luZG93cy5uZXQifQ.fYPjWrNus78FUbnLZP8Bqj2BxUEpkHrwVpjFl_34i38&response-content-disposition=attachment%3B%20filename%3Dfoundry_v1.8.3_win32_amd64.zip&response-content-type=application%2Foctet-stream';
const outputPath = 'D:\\foundry.zip';

const file = fs.createWriteStream(outputPath);
const req = https.get(url, (res) => {
  console.log('STATUS:', res.statusCode);
  res.pipe(file);
  let total = 0;
  res.on('data', chunk => total += chunk.length);
  file.on('finish', () => {
    file.close();
    const stats = fs.statSync(outputPath);
    console.log('DOWNLOADED:', stats.size, 'bytes');
    if (stats.size > 1000000) console.log('SUCCESS: File looks valid!');
  });
}).on('error', (e) => console.log('ERROR:', e.message));

req.setTimeout(60000, () => { console.log('TIMEOUT'); req.destroy(); });
