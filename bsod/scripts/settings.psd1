@{
  General = @{
    WorkRoot          = "work";
    OutputDirName     = "output";
    LogsDir           = "logs";
    RunStateFile      = "scripts/run_state.json";

    AllowedExtensions = @(".dmp",".zip",".001",".z01",".7z");
    MaxTotalSizeGB    = 30;
    RetryCount        = 3;
    RetryBackoffMs    = 800;
    HttpTimeoutSec    = 120;

    UploadMethodPattern = '上传方式[:：]\s*(?<method>.+?)(?:[（(]\s*UID[:：]?\s*(?<uid>[A-Za-z0-9_=/-]{6,64})\s*[）)])?';
    ZipOnlyWhenAttachment = $true;
    MsinfoNameHint    = "msinfo";

    CommentMaxLen     = 64000;
    TitleMaxLen       = 120;

    XpertTimeoutSec   = 1800;
  };
  Auth = @{
    Keycloak = @{
      TokenUrl = "https://auth.platformlabs.lenovo.com/realms/platformlabs/protocol/openid-connect/token"
  
      Username = "bot"
      Password = "platform"
  
      ClientId = "platformlabs-api"
  
      # 可选：scope
      Scope = ""
    }
  }

  Paths = @{
    RepoRootMarker = ".git";             # 可选：用于自动定位仓库根
    KD_DIR         = "windbg/x64";        # 相对仓库根
    XpertExe       = "tools/xpert/xpert.exe"; # 相对仓库根或绝对路径
    SevenZipExeCandidates = @(
      "tools/7-Zip/7z.exe",
      "C:\Program Files\7-Zip\7z.exe",
      "C:\Program Files (x86)\7-Zip\7z.exe"
    );
  };

  Pipeline = @{
    # 需要哪些分析器：顺序=优先级（前者更权威）
    Analyzers = @("kd");

    Persist = @{
      Enable = $true;
      RequireRestApi = $true;  # 非 REST（附件上传）是否允许上报后端
    };

    Publish = @{
      Enable = $true;
    };
  };

  Endpoints = @{
    OpsBaseUrl    = "https://ops.platformlabs.lenovo.com";
    OpsApiPrefix  = "/api/v1";

    GiteaApiPaths = @{
      Issue            = "/api/v1/repos/{repo}/issues/{issue}";
      IssueComments    = "/api/v1/repos/{repo}/issues/{issue}/comments";
      UpdateIssue      = "/api/v1/repos/{repo}/issues/{issue}";
    };

    ApiBaseUrl    = "https://api.platformlabs.lenovo.com";
    ApiApiPrefix  = "/v1";

    ApiPaths = @{
      BsodEvents            = '/bsod/events'
      BsodEventInfo         = '/bsod/events/{uid}/info'
      BsodEventFiles        = '/bsod/events/{uid}/files'
      BsodEventFileDownload = '/bsod/events/{uid}/files/{fileId}/download'
      BsodEventFinalize     = '/bsod/events/{uid}/finalize'
      BsodEventUpdate       = '/bsod/events/{uid}'

      BsodReportUpsert      = '/bsod/events/{uid}/report'
      BsodReportGet         = '/bsod/events/{uid}/report'
      BsodSearch            = '/bsod/search'
    };
  };
}
