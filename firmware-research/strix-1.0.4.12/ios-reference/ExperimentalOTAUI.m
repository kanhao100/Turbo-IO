#import "ExperimentalOTAUI.h"
#import "ExperimentalOTA.h"
#import "ExperimentalOTAFeed.h"
#import "ExperimentalOTAGuard.h"
#import "ExperimentalOTAFlash.h"
#import "ResearchUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TIOExperimentalOTAPage:UITableViewController<UIDocumentPickerDelegate>
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic) BOOL busy;
@property(nonatomic,copy) NSString *directoryStatus;
@end
static NSURL *StoreDirectory(void){return [NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/TurboIOPrivateAddon/ExperimentalOTA"] isDirectory:YES];}
@implementation TIOExperimentalOTAPage
- (void)viewDidLoad{
    [super viewDidLoad];self.title=@"R3 固件实验 · 高风险";self.statusText=@"未选择 ZIP。不会自动查询升级或向眼镜发送指令。";self.directoryStatus=@"尚未检查。只读取官方同版本解压目录，不清理、不覆盖。";TIOStyleResearchTable(self);
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithTitle:@"刷新" style:UIBarButtonItemStylePlain target:self action:@selector(refresh)];
    NSURL *file=[StoreDirectory() URLByAppendingPathComponent:[TIOExperimentalOTASHA() stringByAppendingString:@".zip"]];
    if([NSFileManager.defaultManager fileExistsAtPath:file.path]){self.busy=YES;self.statusText=@"正在重新核对已保存的 R3 副本…";dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSError *error=nil;BOOL ok=TIOReadExperimentalOTA(file,&error)!=nil;dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;self.statusText=ok?@"已恢复 R3 本地副本，完整 SHA-256 复核通过。\n未发送、未安装；不会自动启动升级。":@"已有副本校验失败，已保留原文件，不会发送或覆盖。";[self.tableView reloadData];});});}
}
- (void)refresh{TIORefreshExperimentalOTAReport();[self.tableView reloadData];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView{return 4;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section{return section==2&&TIOOTAFlashBuild()?5:(section==2&&TIOOTAPreparationBuild()?3:(section==0||section==3?2:1));}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section{return @[@"本地包",@"改动与安装范围",@"官方升级流程",@"手机解压目录 · 只读复核"][section];}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path{
    UITableViewCell *cell=[[UITableViewCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];TIOStyleResearchCell(cell);
    if(path.section==0&&path.row==0){cell.textLabel.text=self.busy?@"正在校验…":@"选择 R3 实验 ZIP";cell.detailTextLabel.text=@"从“文件”导入 · 完整 SHA-256 比对 · 不解压、不发送";cell.imageView.image=[UIImage systemImageNamed:@"doc.badge.plus"];cell.accessibilityIdentifier=@"experimental-ota-import";}
    else if(path.section==0){cell.textLabel.text=@"本地校验状态";cell.detailTextLabel.text=self.statusText;cell.accessibilityIdentifier=@"experimental-ota-status";}
    else if(path.section==1){cell.textLabel.text=@"仅 AP 内容变化，不代表只写 AP";cell.detailTextLabel.text=@"Strix OS 1.0.4.12 · Turbo Photo R3\n完整包另有 13 个原样负载；官方安装仍可能写入它们。参考图已获作者公开授权；勿导入未授权的私人内容。\n固定 R3 已有一次用户真机反馈，不保证你的设备能启动或升级通道失效后可恢复。";}
    else if(path.section==2){NSDictionary *feed=TIOExperimentalOTAFeedStatus(),*guard=TIOOTAGuardStatus();
        if(path.row==3){cell.textLabel.text=@"允许一次 R3 实验试刷";cell.detailTextLabel.text=@"重新校验并冻结实际待传文件；限定本次设备、Mode 2、R3 清单及每个分片。授权后再点官方“开始安装”。不保证启动或可救砖。";cell.accessibilityIdentifier=@"experimental-ota-authorize-r3";}
        else if(path.row==4){cell.textLabel.text=@"撤销尚未开始的试刷授权";cell.detailTextLabel.text=@"只有未开始时能撤销。开始后不要强停 App、断电或切换版本。";}
        else if(path.row==0&&TIOOTAFlashBuild()){NSDictionary *s=TIOOTAFlashStatus();cell.textLabel.text=@"R3 SOURCE 01 · 试验用品";cell.detailTextLabel.text=[NSString stringWithFormat:@"授权：%@ · 已开始：%@\n清单匹配：%@ · 已核对分片 %@\n%@",s[@"authorized"],s[@"started"],s[@"manifestMatched"],s[@"validatedSlices"],s[@"failure"]];}
        else if(path.row==1){cell.textLabel.text=@"开启 15 分钟只下载验收";cell.detailTextLabel.text=TIOOTAFlashBuild()?@"只提供固定 R3 下载，不授予试刷权限；需另外明确确认。":@"只向固件查询提供 R3；所有发送被隔离，仅允许读取 OS 版本。官方可能提示发送失败，这是准备阶段的预期。";cell.accessibilityIdentifier=@"experimental-ota-prepare-only";}
        else if(path.row==2){cell.textLabel.text=@"撤销下载来源";cell.detailTextLabel.text=@"停止提供元数据和 ZIP，不等于撤销试刷授权。尚未开始的授权请单独撤销；传输开始后不要操作此项。";cell.accessibilityIdentifier=@"experimental-ota-cancel";}
        else if(TIOOTAPreparationBuild()){cell.textLabel.text=@"PREPARE 02 · 禁止刷写";cell.detailTextLabel.text=[NSString stringWithFormat:@"隔离钩子：%@；已阻止 %@ 次发送\n来源开放：%@ · 固件查询 %@ · App 查询 %@ · 下载 %@\n这是只下载构建，没有解除发送隔离的入口。",[guard[@"transportHookReady"] boolValue]?@"已安装":@"未安装",guard[@"blockedCalls"],[feed[@"armed"] boolValue]?@"是":@"否",feed[@"firmwareQueries"]?:@0,feed[@"appQueries"]?:@0,feed[@"downloadRequests"]?:@0];cell.accessibilityIdentifier=@"experimental-ota-preparation-status";}
        else{cell.textLabel.text=@"刷机门禁关闭 · 不能开始升级";cell.detailTextLabel.text=[feed[@"running"] boolValue]?[NSString stringWithFormat:@"本机升级来源已启动，仅返回“无更新”。已收到 %@ 次查询。\n同版本缓存及官方宿主尚待验收；编译门禁禁止提供实验包。没有发送到眼镜。",feed[@"queryCount"]]:@"本机升级来源组件已编译，当前包未启用实验路由。官方调度尚待验收。\n不覆盖官方缓存、不修改同版本升级开关、不向眼镜发送。";cell.accessibilityIdentifier=@"experimental-ota-not-connected";}}
    else if(path.row==0){cell.textLabel.text=self.busy?@"正在校验…":@"核对官方解压目录";cell.detailTextLabel.text=@"逐个比对 14 文件与清单；旧原厂包不会被当作 R3";cell.accessibilityIdentifier=@"experimental-ota-check-directory";}
    else{cell.textLabel.text=@"目录快照结果";cell.detailTextLabel.text=self.directoryStatus;cell.accessibilityIdentifier=@"experimental-ota-directory-status";}
    cell.selectionStyle=(((path.section==0||path.section==3)&&path.row==0)||(path.section==2&&path.row>0))&&!self.busy?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path{
    [tableView deselectRowAtIndexPath:path animated:YES];if(self.busy)return;
    if(path.section==2&&path.row==4&&TIOOTAFlashBuild()){self.statusText=TIOOTAFlashCancel()?@"未开始的授权已撤销":@"会话已开始，未中断传输；请保持供电和连接";[self refresh];return;}
    if(path.section==2&&path.row==3&&TIOOTAFlashBuild()){
        UIAlertController *a=[UIAlertController alertControllerWithTitle:@"仅授权本次 R3 试刷" message:@"只修改 AP 内容，不保证只写 AP；可能无法启动，原厂 ZIP 不保证能救砖。先关闭官方自动更新。确认当前无录音、提词、导航或对话，电量充足。输入 R3 后授权，随后在官方页面手动开始安装。" preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"R3";f.autocapitalizationType=UITextAutocapitalizationTypeAllCharacters;f.autocorrectionType=UITextAutocorrectionTypeNo;}];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"确认风险并授权" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x){
            if(![a.textFields.firstObject.text isEqual:@"R3"]){self.statusText=@"确认文字不符，未授权";[self refresh];return;}
            NSError *e=nil;BOOL ok=TIOOTAFlashAuthorize(&e);self.statusText=ok?@"本次设备的 R3 文件已冻结，允许一次正常 Mode 2 会话。请返回官方页，手动点开始安装。":e.localizedDescription;[self refresh];
        }]];[self presentViewController:a animated:YES completion:nil];return;
    }
    if(path.section==2&&path.row==2){TIOCancelExperimentalOTAPreparation();[self refresh];return;}
    if(path.section==2&&path.row==1){UIAlertController *confirm=[UIAlertController alertControllerWithTitle:@"只下载验收，不刷眼镜" message:@"此操作只开放 15 分钟本机 R3 下载源，不授予眼镜传输权限，也不会撤销已有试刷授权。请先确认没有已开始的升级；需要试刷时必须单独确认风险并授权。" preferredStyle:UIAlertControllerStyleAlert];[confirm addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];[confirm addAction:[UIAlertAction actionWithTitle:@"只下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){NSError *e=nil;BOOL ok=TIOBeginExperimentalOTAPreparation(&e);self.statusText=ok?@"来源已开放。可回官方页检查并下载；本操作不授予眼镜传输权限。实际门禁状态以授权/已开始字段为准。":e.localizedDescription;[self refresh];}]];[self presentViewController:confirm animated:YES completion:nil];return;}
    if(path.row!=0)return;
    if(path.section==3){self.busy=YES;self.directoryStatus=@"逐个读取并核对 SHA-256…";[self.tableView reloadData];
        NSURL *directory=[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/ota/Strix_OS_1.0.4.12"] isDirectory:YES];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSError *error=nil;NSDictionary *result=TIOCheckExperimentalOTADirectory(directory,&error);dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;self.directoryStatus=result?@"此刻目录中 15 个成员均与 R3 一致。\n仅是目录读取快照，不会发送或改变已有授权。是否允许传输以授权/已开始字段为准。":error.localizedDescription;[self.tableView reloadData];});});return;}
    if(path.section!=0)return;
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];picker.allowsMultipleSelection=NO;picker.delegate=self;[self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls{
    if(self.busy||urls.count!=1)return;self.busy=YES;self.statusText=@"正在读取并核对指定 R3 的完整 SHA-256…";[self.tableView reloadData];
    NSURL *source=urls.firstObject;
    NSURL *directory=StoreDirectory();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        BOOL access=[source startAccessingSecurityScopedResource];NSError *error=nil;NSDictionary *result=TIOImportExperimentalOTA(source,directory,&error);if(access)[source stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(),^{self.busy=NO;self.statusText=result?@"R3 完整文件校验通过，已保存扩展本地副本。\n未向眼镜发送，未开始安装；返回本页不会触发升级。":(error.localizedDescription?:@"导入失败，未发送。");[self.tableView reloadData];});
    });
}
@end
UIViewController *TIOExperimentalOTAController(void){return [[TIOExperimentalOTAPage alloc]initWithStyle:UITableViewStyleInsetGrouped];}
