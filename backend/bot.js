import 'dotenv/config';
import express from 'express';
import path from 'node:path';
import { Telegraf, Markup } from 'telegraf';

const BOT_TOKEN = process.env.BOT_TOKEN;
const WEB_APP_URL = process.env.WEB_APP_URL;
const PORT = Number(process.env.PORT || 3000);

if (!BOT_TOKEN) throw new Error('BOT_TOKEN is missing');
if (!WEB_APP_URL) throw new Error('WEB_APP_URL is missing');

const bot = new Telegraf(BOT_TOKEN);
const app = express();
const ASSET_DIR = path.dirname(new URL(import.meta.url).pathname);

app.get('/', (_req, res) => {
  res.json({ ok: true, service: 'Limt Trading Bot' });
});

app.get('/health', (_req, res) => {
  res.json({ ok: true });
});

const welcomeText = `🟡 LIMT TRADING

مرحباً بك في منصة Limt Trading 👋

منصة احترافية للتحكم في تداول الذهب XAUUSD وإدارة الأوامر والصفقات بسهولة من خلال واجهة تداول سريعة ومتطورة.

📊 من خلال التطبيق يمكنك:
• إضافة أوامر التداول
• متابعة الأوامر والصفقات
• متابعة حالة التنفيذ
• إدارة صفقاتك بسهولة

🚀 جاهز للبدء؟

اضغط على الزر أدناه لفتح منصة التداول.`;

const openButton = Markup.inlineKeyboard([
  [Markup.button.webApp('📊 فتح منصة Limt Trading', WEB_APP_URL)]
]);

bot.start(async (ctx) => {
  try {
    await ctx.replyWithPhoto({ source: path.join(ASSET_DIR, 'welcome.png') }, { caption: welcomeText, ...openButton });
  } catch (error) {
    console.error('Welcome photo error:', error);
    await ctx.reply(welcomeText, openButton);
  }
});

bot.command('help', async (ctx) => {
  await ctx.reply(
    '📚 المساعدة\n\nاضغط على «📊 فتح منصة Limt Trading» للدخول إلى منصة التداول.'
  );
});

bot.catch((err) => {
  console.error('Telegram bot error:', err);
});

app.listen(PORT, () => {
  console.log(`HTTP server listening on port ${PORT}`);
});

bot.launch().then(() => {
  console.log('Limt Trading Bot is running');
});

process.once('SIGINT', () => bot.stop('SIGINT'));
process.once('SIGTERM', () => bot.stop('SIGTERM'));
