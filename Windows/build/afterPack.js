// Sets Texel's icon and name on Texel.exe without needing Windows or Wine (pure JavaScript).
const fs = require('fs');
const path = require('path');

exports.default = async function afterPack(ctx) {
  if (ctx.electronPlatformName !== 'win32') return;
  const ResEdit = await import('resedit');
  const exe = path.join(ctx.appOutDir, `${ctx.packager.appInfo.productFilename}.exe`);
  const ex = ResEdit.NtExecutable.from(fs.readFileSync(exe), { ignoreCert: true });
  const res = ResEdit.NtExecutableResource.from(ex);
  const ico = ResEdit.Data.IconFile.from(fs.readFileSync(path.join(__dirname, 'icon.ico')));
  const groups = ResEdit.Resource.IconGroupEntry.fromEntries(res.entries);
  const gid = groups.length ? groups[0].id : 1, lang = groups.length ? groups[0].lang : 1033;
  ResEdit.Resource.IconGroupEntry.replaceIconsForResource(res.entries, gid, lang, ico.icons.map((i) => i.data));
  const [vi] = ResEdit.Resource.VersionInfo.fromEntries(res.entries);
  const [major, minor, patch] = ctx.packager.appInfo.version.split('.').map(Number);
  vi.setFileVersion(major, minor, patch, 0, 1033);
  vi.setProductVersion(major, minor, patch, 0, 1033);
  vi.setStringValues({ lang: 1033, codepage: 1200 }, {
    ProductName: 'Texel', FileDescription: 'Texel', CompanyName: 'Texel',
    InternalName: 'Texel', OriginalFilename: 'Texel.exe', LegalCopyright: '',
  });
  vi.outputToResourceEntries(res.entries);
  res.outputResource(ex);
  fs.writeFileSync(exe, Buffer.from(ex.generate()));
  console.log('  • set Texel icon and version info on', path.basename(exe));
};
