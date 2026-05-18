# Duo Mobile — Setup Guide

Duo Security was acquired by Cisco in 2018. The app and admin panel are still called **Duo Mobile** and **Duo Security** — the publisher name in app stores shows **Cisco**.

---

## Account

| Field | Value |
|---|---|
| Admin account email | `rra**.cs**@race.reva.edu.in` |
| Admin panel | `admin.duosecurity.com` |
| Signup | `duo.com` — 30-day trial, then **Essentials $3/user/month** |

> Duo requires an institutional or business email. Personal Gmail/Yahoo accounts are rejected. College email works.

---

## Pricing

| Plan | Price | What it adds |
|---|---|---|
| **Essentials** | $3/user/month | MFA, push notifications — sufficient for this project |
| **Advantage** | $6/user/month | Device trust, SSO |
| **Premier** | $9/user/month | Full zero trust suite |

For a small team of analysts (e.g. 5 users) Essentials costs ~$15/month. Verify current pricing at `duo.com/pricing` — Cisco adjusts plans periodically.

> **For dev/lab use**: SMS via AWS SNS (already implemented in the ACP) covers the full CIBA approval flow at near-zero cost. Start the Duo trial only when ready to demo the rich push UX in Phase 2.

---

## Mobile App Install

Duo Mobile is a standard app store install — nothing custom to build.

**iPhone (iOS)**
- Open **App Store** → search `Duo Mobile` → Install
- Publisher: **Cisco Systems, Inc.**

**Android**
- Open **Google Play Store** → search `Duo Mobile` → Install
- Publisher: **Cisco**

---

## Full Setup Sequence

### Step 1 — Create Admin Account

- Go to `duo.com` → **Start free trial**
- Register with an institutional email (e.g. `rra**.cs**@race.reva.edu.in`)
- Verify email → log into `admin.duosecurity.com`

### Step 2 — Create the Auth API Application

1. Admin Panel → **Applications** → **Protect an Application**
2. Search `Auth API` → click **Protect**
3. Note down the credentials shown:

```
Integration Key (ikey):  Dxxxxxxxxxxxxxxxxxx
Secret Key      (skey):  xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
API Hostname    (host):  api-xxxxxxxx.duosecurity.com
```

These are what the ACP service uses to send push notifications.

### Step 3 — Store Credentials in Vault

```bash
vault kv put secret/duo \
  ikey=<Integration Key> \
  skey=<Secret Key> \
  host=<API Hostname>
```

### Step 4 — Add a User (e.g. Sarah)

1. Admin Panel → **Users** → **Add User**
2. Username: `ra**.cs**@race.reva.edu.in`
3. Click **Send Enrollment Email**

### Step 5 — Sarah Enrolls Her Phone

1. Sarah opens the enrollment email
2. Clicks the enrollment link
3. Chooses enrollment method:
   - **QR Code** — if the email was opened on a laptop: scan the QR code with Duo Mobile on her phone
   - **Activation Code** — if the email was opened on the phone itself: copy/type the code into Duo Mobile
4. Duo Mobile confirms enrollment

### Step 6 — Test Push Notification

1. Admin Panel → **Users** → `ra**.cs**@race.reva.edu.in` → **Send Auth Push**
2. Sarah should see an **Approve / Deny** prompt appear in Duo Mobile
3. Tap **Approve** — confirms the channel is working end to end

---

## How Duo Fits into the CIBA Flow

When the security gateway scores a tool call above the HITL threshold (risk > 0.75), the ACP service sends Sarah an approval request. The ACP (`services/ciba-acp/app/main.py`) supports two channels:

| Channel | Requires | UX |
|---|---|---|
| **SMS via AWS SNS** | Phone number in Keycloak user attribute | Text message with approval link |
| **Duo Mobile push** | Duo app installed + device enrolled | In-app Approve/Deny with binding message |

Duo is the **rich channel** — Sarah sees the exact binding message inside the app and taps Approve or Deny without leaving Duo Mobile. SMS is the fallback when Duo is not configured or the user has no Duo enrollment.

The ACP tries Duo first if `preferred_channel = duo` is set on the notify request; falls back to SNS topic if Duo fails or is unconfigured.

---

## References

- [Duo Admin Panel](https://admin.duosecurity.com)
- [Duo Auth API Documentation](https://duo.com/docs/authapi)
- [Keycloak Duo SPI Plugin](https://github.com/mths0x5f/keycloak-duo-spi) — used to integrate Duo push into Keycloak's CIBA flow
- [Duo Mobile — App Store](https://apps.apple.com/app/duo-mobile/id422663827)
- [Duo Mobile — Play Store](https://play.google.com/store/apps/details?id=com.duosecurity.duomobile)
