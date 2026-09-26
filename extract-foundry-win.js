const { execSync } = require('child_process');
const fs = require('fs');

try {
  // Extract using PowerShell
  const result = execSync('powershell "Expand-Archive -Path \'D:\\foundry.zip\' -DestinationPath \'D:\\foundry\' -Force"', { timeout: 60000 });
  console.log('EXTRACT_DONE');
} catch (e) {
  console.log('EXTRACT_ERROR:', e.message);
  // Try using tar
  try {
    const result = execSync('tar -xf D:\\foundry.zip -C D:\\foundry 2>&1', { timeout: 60000 });
    console.log('EXTRACT_DONE_TAR');
  } catch (e2) {
    console.log('EXTRACT_ERROR_TAR:', e2.message);
  }
}

// List extracted files
try {
  const files = fs.readdirSync('D:\\foundry');
  console.log('FILES:', files.join(', '));
  // Recursively list up to 2 levels deep
  function listRecursive(dir, depth) {
    if (depth > 2) return;
    const items = fs.readdirSync(dir, { withFileTypes: true });
    items.forEach(item => {
      const path = `${dir}\\${item.name}`;
      if (item.isDirectory()) {
        console.log('DIR:', path);
        listRecursive(path, depth + 1);
      } else {
        console.log('FILE:', path, item.size, 'bytes');
      }
    });
  }
  listRecursive('D:\\foundry', 0);
} catch (e) {
  console.log('LIST_ERROR:', e.message);
}

// Find forge.exe
try {
  const { execSync: exe } = require('child_process');
  const result = exe('powershell "Get-ChildItem -Path D:\\foundry -Recurse -Name forge.exe 2>&1"', { timeout: 10000 });
  console.log('FORGE_EXE:', result.toString().trim());
} catch (e) {
  console.log('FORGE_NOT_FOUND:', e.message);
}
