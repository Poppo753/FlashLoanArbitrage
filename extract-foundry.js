const fs = require('fs');
const zlib = require('zlib');
const path = require('path');

const zipPath = 'D:\\foundry.zip';
const extractPath = 'D:\\foundry';

if (!fs.existsSync(zipPath)) {
  console.log('FILE_NOT_FOUND');
  process.exit(1);
}

// Extract zip using built-in capabilities
// Since Node.js doesn't have built-in zip, use a simple approach
// Read the zip and try to extract using child_process
const { execSync } = require('child_process');
try {
  execSync(`tar -xf "${zipPath}" -C "${extractPath}"`, { cwd: 'D:\\' });
  console.log('EXTRACT_DONE');
} catch (e) {
  // Try alternative: use PowerShell Expand-Archive
  try {
    execSync(`powershell "Expand-Archive -Path '${zipPath}' -DestinationPath '${extractPath}' -Force"`, { cwd: 'D:\\' });
    console.log('EXTRACT_DONE');
  } catch (e2) {
    console.log('EXTRACT_ERROR:', e2.message);
  }
}

// List extracted files
try {
  const files = fs.readdirSync(extractPath);
  console.log('FILES:', files.join(', '));
} catch (e) {
  console.log('LIST_ERROR:', e.message);
}
