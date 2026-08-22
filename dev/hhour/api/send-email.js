import { Resend } from 'resend';
import { createClient } from '@supabase/supabase-js';
import { applyCors } from './_cors.js';
import { rateLimit, clientIp } from './_ratelimit.js';
import { audit } from './_audit.js';

const resend = new Resend(process.env.RESEND_API_KEY);

export default async function handler(req, res) {
  applyCors(req, res);
  if (req.method === 'OPTIONS') return res.status(204).end();
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }
  const _rl = await rateLimit('send-email:' + clientIp(req), 10, 10 * 60 * 1000);
  if (!_rl.allowed) { audit(req, { type: 'rate_limit', severity: 'warn', meta: { route: 'send-email' } }); res.setHeader('Retry-After', String(_rl.retryAfter)); return res.status(429).json({ error: 'Too many requests — please try again later' }); }

  const { type, email, name, data } = req.body;

  if (!type || !email) {
    return res.status(400).json({ error: 'Missing type or email' });
  }

  // AuthZ — prevent this from being an open relay. The caller must be signed in,
  // and may only email their OWN address unless they are an admin.
  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  const sbUrl = process.env.SUPABASE_URL || 'https://hjzyqhfuvcswfcvkjsyv.supabase.co';
  const sbKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!token || !sbKey) return res.status(401).json({ error: 'Not signed in' });
  try {
    const sb = createClient(sbUrl, sbKey, { auth: { persistSession: false } });
    let callerId = null, callerEmail = '';
    const { data: who } = await sb.auth.getUser(token);
    if (who && who.user) {
      callerId = who.user.id; callerEmail = who.user.email || '';
    } else {
      // getUser can reject valid sb_secret_-era tokens — fall back to the JWT sub.
      try {
        const payload = JSON.parse(Buffer.from(token.split('.')[1] || '', 'base64').toString('utf8'));
        if (payload && payload.sub) {
          const { data: byId } = await sb.auth.admin.getUserById(payload.sub);
          if (byId && byId.user) { callerId = byId.user.id; callerEmail = byId.user.email || ''; }
        }
      } catch (e) {}
      if (!callerId) return res.status(401).json({ error: 'Invalid session' });
    }
    const { data: prof } = await sb.from('profiles').select('role').eq('id', callerId).single();
    const isAdmin = !!prof && ['admin', 'super_admin'].includes(prof.role);
    if (!isAdmin && callerEmail.toLowerCase() !== String(email).toLowerCase()) {
      audit(req, { type: 'permission_denied', severity: 'warn', actor: callerId, meta: { route: 'send-email', reason: 'not_own_address' } });
      return res.status(403).json({ error: 'You can only email your own address' });
    }
  } catch (e) {
    return res.status(401).json({ error: 'Auth check failed' });
  }

  let subject, html, attachments = null;

  // Welcome email for new users
  if (type === 'welcome') {
    subject = `Welcome to Appie Hour, ${name}!`;
    html = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h1>Welcome to Appie Hour! 🍻</h1>
        <p>Hi ${name},</p>
        <p>Thanks for joining Appie Hour! You're now part of a community that loves finding great happy hour deals and events.</p>
        <h3>Get Started:</h3>
        <ul>
          <li>Browse exclusive deals at your favorite bars and restaurants</li>
          <li>Find events happening near you</li>
          <li>Share your favorite spots with the community</li>
          <li>Customize your preferences in Settings</li>
        </ul>
        <p style="margin-top: 30px; font-size: 12px; color: #666;">
          Questions? Reply to this email or visit our help center.
        </p>
      </div>
    `;
  }

  // Deal notification
  if (type === 'deal-notification') {
    const { dealName, discount, venue } = data || {};
    subject = `🎉 New Deal Alert: ${dealName} at ${venue}`;
    html = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h1>New Deal Near You! 🎉</h1>
        <p>Hi ${name},</p>
        <p><strong>${dealName}</strong> at <strong>${venue}</strong> is now available!</p>
        <p>Discount: <span style="font-size: 24px; color: #ff6b35; font-weight: bold;">${discount}</span></p>
        <p><a href="https://appiehour.com" style="background-color: #ff6b35; color: white; padding: 10px 20px; text-decoration: none; border-radius: 5px; display: inline-block;">Check it out</a></p>
      </div>
    `;
  }

  // Order/Booking confirmation
  if (type === 'booking-confirmation') {
    const { bookingId, venue, date, time } = data || {};
    subject = `Booking Confirmed at ${venue}`;
    html = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h1>Booking Confirmed! ✅</h1>
        <p>Hi ${name},</p>
        <p>Your booking at <strong>${venue}</strong> is confirmed!</p>
        <div style="background-color: #f0f0f0; padding: 15px; border-radius: 5px; margin: 20px 0;">
          <p><strong>Booking ID:</strong> ${bookingId}</p>
          <p><strong>Venue:</strong> ${venue}</p>
          <p><strong>Date:</strong> ${date}</p>
          <p><strong>Time:</strong> ${time}</p>
        </div>
        <p>See you soon! 🍻</p>
      </div>
    `;
  }

  // Order notification (generic)
  if (type === 'order-confirmation') {
    const { orderId, total } = data || {};
    subject = `Order Confirmed - #${orderId}`;
    html = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h1>Order Confirmed! ✅</h1>
        <p>Hi ${name},</p>
        <p>Thanks for your order! Here are your details:</p>
        <div style="background-color: #f0f0f0; padding: 15px; border-radius: 5px; margin: 20px 0;">
          <p><strong>Order ID:</strong> ${orderId}</p>
          <p><strong>Total:</strong> $${total}</p>
        </div>
        <p>We'll send you updates as your order progresses.</p>
      </div>
    `;
  }

  // DSAR — request received (sent to the customer when they request their data)
  if (type === 'data-request-received') {
    subject = `We've received your data request`;
    html = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h1>Your data request 📩</h1>
        <p>Hi ${name || 'there'},</p>
        <p>We've received your request for a copy of your personal data. To protect your account, our team will <strong>verify your request</strong> before preparing the export.</p>
        <p>We'll email you again as soon as your export is ready. This is usually completed within 30 days, as required by data-protection law.</p>
        <p style="margin-top: 30px; font-size: 12px; color: #666;">If you didn't make this request, please contact us via Help &amp; Support right away.</p>
      </div>
    `;
  }

  // DSAR — export ready (sent by an admin/DPO when releasing the export).
  // The export file is attached to THIS email (data.attachment = { filename, content:base64 }).
  if (type === 'data-export-ready') {
    const att = data && data.attachment;
    const hasFile = att && att.content && att.filename;
    if (hasFile) {
      attachments = [{ filename: String(att.filename), content: String(att.content) }];
    }
    subject = `Your data export is ready`;
    html = `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
        <h1>Your data export is ready ✅</h1>
        <p>Hi ${name || 'there'},</p>
        <p>We've verified your request and prepared a copy of your personal data.</p>
        <p>${hasFile ? 'Your export is <strong>attached to this email</strong> as a JSON file.' : 'Our team will send your export file to you shortly.'}</p>
        <p style="margin-top: 30px; font-size: 12px; color: #666;">Questions about your data? Just reply to this email.</p>
      </div>
    `;
  }

  if (!subject || !html) {
    return res.status(400).json({ error: 'Unknown email type' });
  }

  try {
    const { data, error } = await resend.emails.send({
      from: 'Appie Hour <noreply@appiehour.com>',
      to: email,
      subject: subject,
      html: html,
      ...(attachments ? { attachments } : {}),
    });

    // Resend SDK v3 returns errors in `error`, not by throwing — surface them.
    if (error) {
      console.error('Resend send error:', error);
      return res.status(502).json({ error: error.message || 'Resend rejected the send', name: error.name });
    }

    return res.status(200).json({ success: true, id: data && data.id });
  } catch (error) {
    console.error('Email send exception:', error);
    return res.status(500).json({ error: error.message });
  }
}
