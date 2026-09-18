/**
 * 端到端测试：用带「假摄像头 / 假麦克风」的 Chrome 模拟手机端，
 * 验证 PC 服务能否收到视频帧与音频块。
 */
const puppeteer = require('puppeteer-core');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const URL = process.env.TEST_URL || 'http://localhost:8080';
const DURATION = Number(process.env.TEST_SECONDS || 10);

(async () => {
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: 'new',
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      '--autoplay-policy=no-user-gesture-required',
      '--no-sandbox',
      '--disable-dev-shm-usage',
      '--window-size=480,900',
    ],
  });

  const page = await browser.newPage();
  await page.setViewport({ width: 420, height: 860 });
  const logs = [];
  page.on('console', m => logs.push('[console] ' + m.text()));
  page.on('pageerror', e => logs.push('[pageerror] ' + e.message));

  console.log('打开页面:', URL);
  await page.goto(URL, { waitUntil: 'domcontentloaded' });
  await new Promise(r => setTimeout(r, 1500));

  console.log('点击「开始」…');
  await page.click('#btnStart');

  console.log(`推流 ${DURATION} 秒…`);
  await new Promise(r => setTimeout(r, DURATION * 1000));

  const state = await page.evaluate(() => ({
    conn: document.getElementById('connText').textContent,
    fps: document.getElementById('fpsBadge').textContent,
    log: document.getElementById('log').textContent,
    btn: document.getElementById('btnStart').textContent,
  }));

  console.log('\n=== 手机端页面状态 ===');
  console.log(JSON.stringify(state, null, 2));

  if (logs.length) {
    console.log('\n=== 页面控制台 ===');
    console.log(logs.join('\n'));
  }

  await browser.close();
  console.log('\n浏览器已关闭');
})().catch(e => {
  console.error('测试失败:', e.message);
  process.exit(1);
});
