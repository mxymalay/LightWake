from pathlib import Path
import json, os, plistlib, shutil, subprocess
from prepare_widgetkit_overlay import prepare_widgetkit_overlay
base=Path(__file__).resolve().parent
icon=base/'assets/SystemStatus.icns'
if not icon.is_file():raise FileNotFoundError(f'Missing app icon: {icon}')
sdk=subprocess.check_output(['xcrun','--show-sdk-path'],text=True).strip()
compiler_overlays=prepare_widgetkit_overlay(base,sdk)
toolchain=str(Path(subprocess.check_output(['xcrun','--find','swiftc'],text=True).strip()).resolve().parents[2])
xcode_version_file=next((parent/'version.plist' for parent in Path(toolchain).parents if (parent/'version.plist').is_file()),None)
if xcode_version_file is None:raise RuntimeError('Select a full Xcode installation with xcode-select before building.')
xcode_build=plistlib.loads(xcode_version_file.read_bytes())['ProductBuildVersion']
metadata=base/'build/metadata'
metadata.mkdir(parents=True,exist_ok=True)
app=base/'build/系统状态.app'
ext=app/'Contents/PlugIns/SystemStatusWidget.appex'
shared=[base/n for n in ['SystemMetrics.swift','PowerDiskMetrics.swift','WidgetUI.swift','SimpleWidgetUI.swift']]
for role,target,module,source,package,bundle in [('widget',ext,'SystemStatusWidget','WidgetExtension.swift','XPC!','local.xy.system-status.widget'),('host',app,'SystemStatus','HostApp.swift','APPL','local.xy.system-status')]:
    contents=target/'Contents'
    (contents/'MacOS').mkdir(parents=True,exist_ok=True)
    resources=contents/'Resources';resources.mkdir(exist_ok=True)
    shutil.copy2(icon,resources/icon.name)
    files=shared+[base/source]
    const=metadata/f'{module}.swiftconstvalues'
    cmd=['xcrun','swiftc','-sdk',sdk,'-F',str(compiler_overlays),'-swift-version','5','-target','arm64-apple-macos15.0','-parse-as-library','-O','-whole-module-optimization','-module-name',module,'-emit-executable','-emit-const-values-path',str(const),'-Xfrontend','-const-gather-protocols-file','-Xfrontend',str(base/'const-protocols.json')]
    if role=='widget':cmd+=['-application-extension','-Xlinker','-application_extension','-Xlinker','-e','-Xlinker','_NSExtensionMain']
    cmd+=list(map(str,files))+['-o',str(contents/'MacOS'/module)]
    subprocess.run(cmd,check=True)
    source_list=metadata/f'{module}-sources.list';source_list.write_text('\n'.join(map(str,files))+'\n')
    const_list=metadata/f'{module}-const.list';const_list.write_text(str(const)+'\n')
    subprocess.run(['xcrun','appintentsmetadataprocessor','--output',str(resources),'--toolchain-dir',toolchain,'--module-name',module,'--sdk-root',sdk,'--xcode-version',xcode_build,'--platform-family','macOS','--deployment-target','15.0','--target-triple','arm64-apple-macos15.0','--source-file-list',str(source_list),'--swift-const-vals-list',str(const_list)],check=True)
    info={'CFBundleDevelopmentRegion':'zh_CN','CFBundleDisplayName':'系统状态','CFBundleExecutable':module,'CFBundleIdentifier':bundle,'CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'系统状态','CFBundlePackageType':package,'CFBundleShortVersionString':'1.3.1','CFBundleVersion':'8','CFBundleIconFile':'SystemStatus','LSMinimumSystemVersion':'15.0','NSHighResolutionCapable':True}
    if role=='widget':info['NSExtension']={'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}
    else:info['NSPrincipalClass']='NSApplication'
    with (contents/'Info.plist').open('wb') as f:plistlib.dump(info,f)
    subprocess.run(['/usr/bin/codesign','--force','--sign','-','--entitlements',str(base/'Sandbox.entitlements'),str(target)],check=True)
subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',str(app)],check=True)
print('Built and signed:',app)
