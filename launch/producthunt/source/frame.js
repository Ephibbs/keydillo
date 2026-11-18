const {chromium}=require('playwright');
(async()=>{const b=await chromium.launch();const p=await b.newPage({viewport:{width:800,height:440},deviceScaleFactor:3});
await p.goto('file://'+process.cwd()+'/first-run.html');
await p.addStyleTag({content:'.dim{left:40px!important;top:28px!important;width:720px;height:384px;border-radius:12px}body{font-family:Inter,sans-serif!important}.term,.ln code,.sv pre{font-family:"JetBrains Mono",monospace!important}'});
for(const [t,n] of [[11300,'frame-touchid'],[5900,'frame-paste'],[14500,'frame-done']]){await p.evaluate(t=>render(t),t);await p.screenshot({path:n+'.png'});}
await b.close();})();
