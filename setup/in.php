<?php
// Runs inside the Invoice Ninja container for the DSM package: piped to `php`
// (as www-data) with one line in front setting $ACT and $ARG_B64 (base64
// JSON) — so passwords travel on stdin, never in argv or env. Invoice Ninja is
// booted and its own models do the work. Prints one JSON line: {"ok":…, …}.
require '/var/www/html/vendor/autoload.php';
$app = require '/var/www/html/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();

use App\Models\User;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Facades\Mail;

function out(array $o) { echo json_encode($o, JSON_UNESCAPED_SLASHES), "\n"; exit(!empty($o['ok']) ? 0 : 1); }
$arg = json_decode(base64_decode($ARG_B64), true) ?: [];

try {
    switch ($ACT) {
        case 'setpw':     // a new password (the first one replaces the throwaway the image's first start needed)
            $u = User::where('email', $arg['email'])->first();
            if (!$u) out(['ok' => false, 'msg' => "There's no user " . $arg['email'] . ' in Invoice Ninja.']);
            $u->forceFill(['password' => Hash::make($arg['password'])])->save();
            if (!empty($arg['name'])) { $p = explode(' ', $arg['name'], 2); $u->forceFill(['first_name' => $p[0], 'last_name' => $p[1] ?? ''])->save(); }
            out(['ok' => true]);

        case 'mfaoff':    // two-step sign-in off, for someone who lost their phone
            $u = User::where('email', $arg['email'])->first();
            if (!$u) out(['ok' => false, 'msg' => "There's no user " . $arg['email'] . '.']);
            $u->forceFill(['google_2fa_secret' => null])->save();
            out(['ok' => true]);

        case 'mailtest':  // the mail settings, tried for real
            Mail::raw("This is a test from the Invoice Ninja package in DSM. If you can read it, Invoice Ninja can email your invoices.", function ($m) use ($arg) {
                $m->to($arg['to'])->subject('Invoice Ninja on your Synology: test email');
            });
            out(['ok' => true]);

        default:
            out(['ok' => false, 'msg' => 'unknown action']);
    }
} catch (Throwable $e) {
    out(['ok' => false, 'msg' => mb_substr(preg_replace('/\s+/', ' ', $e->getMessage()), 0, 300)]);
}
