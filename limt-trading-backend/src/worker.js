const WEB_APP_URL =
  "https://spreadsupposed-jpg.github.io/BOTPPP/Yetimmm.html";

const WELCOME_TEXT = `🟡 <b>LIMT TRADING</b>

━━━━━━━━━━━━━━━━━━

📊 <b>التداول الاحترافي للذهب</b>

مرحباً بك في منصة Limt Trading 👋

منصة للتحكم في تداول الذهب <b>XAUUSD</b> وإدارة الأوامر والصفقات بسهولة.

⚡ تحكم سريع في التداول
📈 متابعة الأوامر والصفقات
🛡️ تنفيذ منظم
🎯 واجهة احترافية

━━━━━━━━━━━━━━━━━━

🚀 <b>جاهز للبدء؟</b>

اضغط على الزر أدناه لفتح منصة التداول.`;

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      "content-type": "application/json; charset=UTF-8",
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,OPTIONS",
      "access-control-allow-headers": "Content-Type, Authorization",
    },
  });
}

function telegramUrl(token, method) {
  return `https://api.telegram.org/bot${token}/${method}`;
}

async function telegram(env, method, body) {
  const response = await fetch(telegramUrl(env.BOT_TOKEN, method), {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });

  const data = await response.json();
  if (!data.ok) {
    throw new Error(data.description || "Telegram API error");
  }
  return data;
}

async function handleTelegramUpdate(update, env) {
  const message = update?.message;
  if (!message?.chat?.id) return;

  const text = (message.text || "").trim();

  if (text === "/start" || text.startsWith("/start ")) {
    await telegram(env, "sendMessage", {
      chat_id: message.chat.id,
      text: WELCOME_TEXT,
      parse_mode: "HTML",
      reply_markup: {
        inline_keyboard: [
          [
            {
              text: "📊 فتح منصة Limt Trading",
              web_app: { url: env.WEB_APP_URL || WEB_APP_URL },
            },
          ],
        ],
      },
    });
    return;
  }

  if (text === "/help") {
    await telegram(env, "sendMessage", {
      chat_id: message.chat.id,
      text:
        "📌 <b>Limt Trading</b>\\n\\n" +
        "اضغط على زر فتح المنصة للوصول إلى واجهة التداول.",
      parse_mode: "HTML",
      reply_markup: {
        inline_keyboard: [
          [
            {
              text: "📊 فتح المنصة",
              web_app: { url: env.WEB_APP_URL || WEB_APP_URL },
            },
          ],
        ],
      },
    });
  }
}

async function handleApi(request, env) {
  const url = new URL(request.url);

  if (request.method === "OPTIONS") {
    return json({ ok: true });
  }

  if (url.pathname === "/health") {
    return json({
      ok: true,
      service: "limt-trading-cloudflare",
      timestamp: new Date().toISOString(),
    });
  }

  if (url.pathname === "/api/config" && request.method === "GET") {
    return json({
      ok: true,
      webAppUrl: env.WEB_APP_URL || WEB_APP_URL,
      symbol: "XAUUSD",
    });
  }

  // نقطة استقبال الأوامر للمرحلة القادمة.
  // لا يتم تنفيذ أي صفقة حقيقية هنا بعد.
  if (url.pathname === "/api/orders" && request.method === "POST") {
    const body = await request.json().catch(() => null);

    if (!body) {
      return json({ ok: false, error: "Invalid JSON" }, 400);
    }

    return json({
      ok: true,
      message: "Order received. MT5 execution will be connected in the next step.",
      order: body,
      receivedAt: new Date().toISOString(),
    });
  }

  return json({ ok: false, error: "Not found" }, 404);
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);

      if (request.method === "OPTIONS") {
        return json({ ok: true });
      }

      if (url.pathname === "/telegram/webhook" && request.method === "POST") {
        const update = await request.json();
        await handleTelegramUpdate(update, env);
        return json({ ok: true });
      }

      return await handleApi(request, env);
    } catch (error) {
      return json(
        {
          ok: false,
          error: error instanceof Error ? error.message : "Internal error",
        },
        500
      );
    }
  },
};
