from pathlib import Path
import plistlib
from prepare_widgetkit_overlay import prepare_widgetkit_overlay
base=Path(__file__).parent
prepare_widgetkit_overlay(base)
objects={}
count=0
def add(data):
    global count
    count+=1
    key=f'{count:024X}'
    objects[key]=data
    return key

def configs(settings):
    cfgs=[add({'isa':'XCBuildConfiguration','name':name,'buildSettings':settings.copy()}) for name in ['Debug','Release']]
    return add({'isa':'XCConfigurationList','buildConfigurations':cfgs,'defaultConfigurationIsVisible':0,'defaultConfigurationName':'Release'})

files={}
for name in ['SystemMetrics.swift','PowerDiskMetrics.swift','WidgetUI.swift','SimpleWidgetUI.swift','HostApp.swift','WidgetExtension.swift']:
    files[name]=add({'isa':'PBXFileReference','lastKnownFileType':'sourcecode.swift','path':name,'sourceTree':'<group>'})
files['assets/SystemStatus.icns']=add({'isa':'PBXFileReference','lastKnownFileType':'image.icns','path':'assets/SystemStatus.icns','sourceTree':'<group>'})
products={}
for name,kind in [('系统状态.app','wrapper.application'),('SystemStatusWidget.appex','wrapper.app-extension')]:
    products[name]=add({'isa':'PBXFileReference','explicitFileType':kind,'includeInIndex':0,'path':name,'sourceTree':'BUILT_PRODUCTS_DIR'})
productgroup=add({'isa':'PBXGroup','children':list(products.values()),'name':'Products','sourceTree':'<group>'})
group=add({'isa':'PBXGroup','children':list(files.values())+[productgroup],'sourceTree':'<group>'})
common={
    'SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'15.0','SWIFT_VERSION':'5.0',
    'CODE_SIGN_STYLE':'Manual','CODE_SIGN_IDENTITY':'-','CODE_SIGN_ENTITLEMENTS':'Sandbox.entitlements',
    'ENABLE_APP_SANDBOX':'YES','ENABLE_HARDENED_RUNTIME':'NO','CLANG_ENABLE_MODULES':'YES',
    'SWIFT_OPTIMIZATION_LEVEL':'-O','GENERATE_INFOPLIST_FILE':'NO',
    'MARKETING_VERSION':'1.3.1','CURRENT_PROJECT_VERSION':'8',
    'FRAMEWORK_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/build/compiler-overlays'],
}
def sources(names):
    buildfiles=[add({'isa':'PBXBuildFile','fileRef':files[n]}) for n in names]
    return add({'isa':'PBXSourcesBuildPhase','buildActionMask':2147483647,'files':buildfiles,'runOnlyForDeploymentPostprocessing':0})
def resources():
    icon=add({'isa':'PBXBuildFile','fileRef':files['assets/SystemStatus.icns']})
    return add({'isa':'PBXResourcesBuildPhase','buildActionMask':2147483647,'files':[icon],'runOnlyForDeploymentPostprocessing':0})
shared=['SystemMetrics.swift','PowerDiskMetrics.swift','WidgetUI.swift','SimpleWidgetUI.swift']
extsettings=common|{'PRODUCT_NAME':'SystemStatusWidget','PRODUCT_BUNDLE_IDENTIFIER':'local.xy.system-status.widget','INFOPLIST_FILE':'WidgetInfo.plist','APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks','@executable_path/../../../../Frameworks']}
exttarget=add({'isa':'PBXNativeTarget','buildConfigurationList':configs(extsettings),'buildPhases':[sources(shared+['WidgetExtension.swift']),resources()],'buildRules':[],'dependencies':[],'name':'SystemStatusWidget','productName':'SystemStatusWidget','productReference':products['SystemStatusWidget.appex'],'productType':'com.apple.product-type.app-extension'})
embedded=add({'isa':'PBXBuildFile','fileRef':products['SystemStatusWidget.appex'],'settings':{'ATTRIBUTES':['RemoveHeadersOnCopy']}})
embedphase=add({'isa':'PBXCopyFilesBuildPhase','buildActionMask':2147483647,'dstPath':'','dstSubfolderSpec':13,'files':[embedded],'name':'Embed App Extensions','runOnlyForDeploymentPostprocessing':0})
dependency=add({'isa':'PBXTargetDependency','target':exttarget})
hostsettings=common|{'PRODUCT_NAME':'系统状态','PRODUCT_BUNDLE_IDENTIFIER':'local.xy.system-status','INFOPLIST_FILE':'HostInfo.plist','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks']}
hosttarget=add({'isa':'PBXNativeTarget','buildConfigurationList':configs(hostsettings),'buildPhases':[sources(shared+['HostApp.swift']),resources(),embedphase],'buildRules':[],'dependencies':[dependency],'name':'SystemStatus','productName':'系统状态','productReference':products['系统状态.app'],'productType':'com.apple.product-type.application'})
project=add({'isa':'PBXProject','attributes':{'LastUpgradeCheck':'2600'},'buildConfigurationList':configs({}),'compatibilityVersion':'Xcode 14.0','developmentRegion':'zh-Hans','hasScannedForEncodings':0,'knownRegions':['en','zh-Hans','Base'],'mainGroup':group,'productRefGroup':productgroup,'projectDirPath':'','projectRoot':'','targets':[hosttarget,exttarget]})
root={'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project}
(base/'SystemStatus.xcodeproj').mkdir(exist_ok=True)
with (base/'SystemStatus.xcodeproj/project.pbxproj').open('wb') as f: plistlib.dump(root,f,sort_keys=False)
for name,package,extra in [('HostInfo.plist','APPL',{'NSPrincipalClass':'NSApplication'}),('WidgetInfo.plist','XPC!',{'NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}})]:
    info={'CFBundleDevelopmentRegion':'zh_CN','CFBundleDisplayName':'系统状态','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'系统状态','CFBundlePackageType':package,'CFBundleShortVersionString':'1.3.1','CFBundleVersion':'8','CFBundleIconFile':'SystemStatus','LSMinimumSystemVersion':'$(MACOSX_DEPLOYMENT_TARGET)'}|extra
    with (base/name).open('wb') as f:plistlib.dump(info,f)
if not (base/'Sandbox.entitlements').exists():
    with (base/'Sandbox.entitlements').open('wb') as f:plistlib.dump({'com.apple.security.app-sandbox':True},f)
print('Xcode project created.')
