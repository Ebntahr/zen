# دليل Zen OS

دليل مختصر للمستخدم والمطوّر. للتفاصيل التقنية بالإنجليزية راجع
[ARCHITECTURE.md](ARCHITECTURE.md) و [APP_DEVELOPMENT.md](APP_DEVELOPMENT.md)
و [HOSTED.md](HOSTED.md).

## 1. ما هو Zen OS؟

نظام تشغيل مكتوب بالكامل بلغة Zig لمعمارية riscv64:

- **نواة مصغّرة (microkernel):** كل شيء عنوان URL كما في Redox. الملفات
  (`file:`) والنوافذ (`window:`) ومعلومات النظام (`sys:`) والشبكة (`tcp:`,
  `dns:`) كلها "مخططات" (schemes) تخدمها برامج مستقلة في مساحة المستخدم.
- **واجهة سطح مكتب** بمظهر macOS 26 و Liquid Glass: شريط قوائم، Dock،
  مبدّل التطبيقات، Spotlight، مركز التحكم، إشعارات.
- **أمان:** مستخدمون وكلمات مرور (Argon2id)، `sudo`، حاويات للتطبيقات
  (App Sandbox)، توقيع رقمي للتطبيقات (Gatekeeper).
- **POSIX:** صدفة `zensh` وأكثر من 90 أداة أساسية في `zbox`، ودعم C/C++.

> **الحالة:** كل ما فوق النواة جاهز ومختبَر. النواة نفسها غير مكتملة (إدارة
> الذاكرة ومعالجة المقاطعات والجدولة واستدعاءات النظام). لذلك تعمل البرامج
> اليوم في **النسخة المستضافة** فوق نواة Linux، وهي البرامج نفسها التي
> ستعمل على Zen، وليست محاكاة.

## 2. التشغيل

### على Linux

```sh
zig build run-hosted
```

ثم افتح `http://127.0.0.1:6080` في المتصفح. المستخدم `zen` وكلمة المرور `zen`.

خيارات المشغّل `zig-out/hosted/zen-hosted`:

| الخيار | الافتراضي | المعنى |
|---|---|---|
| `--size 1440x900` | 1280x800 | حجم الشاشة |
| `--http 6080` | 6080 | منفذ عميل المتصفح |
| `--vnc 5900` | 5900 | منفذ برامج VNC (القيمة 0 تعطّله) |
| `--bind 0.0.0.0` | 127.0.0.1 | عنوان الاستماع (للوصول من جهاز آخر) |

`Ctrl-C` في الطرفية يُغلق النظام بشكل سليم.

### عبر Docker (Linux و macOS و Windows)

```sh
zig build hosted
docker build -t zen-os zig-out/hosted
docker run --rm --hostname zen-os -p 127.0.0.1:6080:6080 -p 127.0.0.1:5900:5900 zen-os
```

### من جهاز آخر

عند الاتصال من غير الجهاز نفسه، يضغط الخادم الصورة تلقائياً (أصغر بحوالي
6 مرات)، فيعمل النظام بسلاسة عبر الشبكة. يمكن أيضاً استخدام أي برنامج VNC
على المنفذ 5900.

### شريط أدوات المتصفح

- **Fit:** ملاءمة الشاشة لحجم النافذة.
- **⛶:** ملء الشاشة.
- **↻:** إعادة الاتصال.
- **Ctrl ⇄ ⌘:** يجعل Ctrl يعمل كمفتاح ⌘ (مثلاً Ctrl+C للنسخ)، ومفتاح Windows
  يصبح Ctrl. هذا مفيد على Windows و Linux.

النسخ واللصق يعملان في الاتجاهين بين جهازك و Zen.

## 3. سطح المكتب

### اختصارات لوحة المفاتيح

| الاختصار | الوظيفة |
|---|---|
| ⌘ Space | Spotlight: البحث عن التطبيقات وفتحها |
| ⌘ Tab | التبديل بين التطبيقات (Esc للإلغاء) |
| ⌘ Q | إنهاء التطبيق |
| ⌘ H | إخفاء التطبيق |
| ⌘ M | تصغير النافذة إلى الـ Dock |
| ⌘ W | إغلاق النافذة |
| ⌘ N | نافذة جديدة في Terminal، أو مستند جديد في TextEdit |
| ⌘ C / ⌘ V / ⌘ X | نسخ / لصق / قص |
| ⌘ Z | تراجع (TextEdit) |
| ⌘ ⇧ 3 | لقطة شاشة تُحفظ على سطح المكتب |
| ⌃ ⌘ Q | قفل الشاشة |
| ⌃ Space أو ⌥ ⇧ | تبديل لغة لوحة المفاتيح (English ⇄ العربية) |

### النوافذ

- **الأزرار الثلاثة** أعلى يسار النافذة: إغلاق، تصغير، تكبير.
- **النقر المزدوج على شريط العنوان** يكبّر النافذة أو يعيدها لحجمها.
- **سحب النافذة إلى الحافة اليسرى أو اليمنى** يجعلها تملأ نصف الشاشة، و**إلى
  الأعلى** يجعلها تملأ الشاشة.

### مركز التحكم

انقر على الجزء الأيمن من شريط القوائم (الساعة والأيقونات). ستجد:

- الوضع الداكن؛
- مصدر الإدخال (لغة لوحة المفاتيح)؛
- اختصاراً إلى الإعدادات؛
- قفل الشاشة.

### لوحة المفاتيح العربية

بدّل اللغة بـ `⌃ Space` أو `⌥ ⇧` أو من مركز التحكم. النص العربي يُشكَّل
ويُعرض من اليمين لليسار تلقائياً في كل التطبيقات (خط Noto Sans Arabic).
المتصفح يرسل مواقع المفاتيح الفعلية، لذلك يتم التبديل داخل Zen نفسه لا في
نظام جهازك.

## 4. التطبيقات

| التطبيق | الوصف |
|---|---|
| **Finder** | تصفح الملفات بعرض الأيقونات أو القائمة، الشريط الجانبي، إنشاء المجلدات وإعادة التسمية وسلة المهملات، فتح الملفات بالتطبيق المناسب |
| **Terminal** | طرفية بألوان كاملة وعدة نوافذ، تشغّل `zensh` |
| **TextEdit** | محرر نصوص يدعم العربية، مع الفتح والحفظ والتراجع |
| **Preview** | عارض صور PNG و PPM/PGM مع التكبير والتحريك |
| **Calculator** | آلة حاسبة (تعمل داخل حاوية معزولة) |
| **Activity Monitor** | العمليات واستهلاك المعالج والذاكرة، وإنهاء العمليات أو إيقافها قسراً |
| **System Settings** | الإعدادات (القسم التالي) |

### الإعدادات (System Settings)

- **General:** حول النظام، تحديث البرامج، التاريخ والوقت والمنطقة الزمنية،
  اللغة والمنطقة، المشاركة.
- **Appearance:** فاتح أو داكن، لون التمييز، تقليل الشفافية.
- **Wallpaper** و **Displays** و **Keyboard**.
- **Users & Groups:** إضافة المستخدمين وتغيير كلمات المرور وصلاحيات المدير.
- **Privacy & Security:** صلاحيات التطبيقات و Gatekeeper.
- **Lock Screen:** شاشة التوقف ومتى تُطلب كلمة المرور.
- **Storage** و **Developer** (أدوات C/C++ و Zig).

## 5. الطرفية

الصدفة `zensh` متوافقة مع POSIX sh، مع إضافات تفاعلية:

- إكمال بالـ Tab للأوامر والمسارات؛
- تلوين الأوامر أثناء الكتابة؛
- سجل الأوامر (الأسهم و `⌃R`)؛
- إدارة المهام (`&` و `jobs` و `fg` و `bg`)؛
- توسيع الأقواس (`{1..3}`) والحساب (`$((…))`).

أوامر مفيدة:

```sh
zenfetch                 # معلومات النظام مع شعار Zen
open notes.txt           # فتح ملف بالتطبيق الافتراضي
open -a TextEdit x.txt   # فتح ملف بتطبيق محدد
open -R photo.png        # إظهار الملف في Finder
open .                   # فتح المجلد الحالي في Finder
sudo -i                  # صدفة بصلاحيات الجذر (لأعضاء مجموعة admin)
passwd                   # تغيير كلمة المرور
cat sys:uname            # معلومات النواة عبر عنوان URL
ls sys:proc              # العمليات
```

أدوات `zbox` (أكثر من 90 أداة) تشمل: `ls cp mv rm mkdir cat less grep sed
find sort uniq wc head tail cut tr xargs diff du df ps kill xxd od base64
sha256sum date seq tree` وغيرها. القائمة الكاملة في `userland/zbox/cmd/`،
ويعرض `zbox --list` كل الأدوات و `COMMAND --help` تعليمات كل واحدة.

## 6. البرمجة بلغتي C و C++

المترجم متاح داخل Zen نفسه (في النسخة المستضافة، ومن الصورة المبنية بـ
`-Dtoolchain=...`):

```sh
cat > hello.c <<'EOF'
#include <stdio.h>
int main(void) { printf("مرحباً من Zen\n"); return 0; }
EOF
cc hello.c -o hello && ./hello
c++ -std=c++20 app.cpp -o app && ./app
```

الأوامر `cc` و `c++` و `gcc` و `g++` و `ar` و `ld` متوفرة. البرامج تُبنى لـ
musl وتستخدم واجهة استدعاءات Linux، لذلك تعمل شيفرة POSIX العادية كما هي
(stdio و pthreads و `opendir("sys:proc")`).

ومن جهاز التطوير:

```sh
zig cc  -target riscv64-linux-musl -static -O2 hello.c -o hello
zig c++ -target riscv64-linux-musl -static -O2 app.cpp -o app
```

## 7. تطوير تطبيقات سطح المكتب بـ Zig

التطبيقات تستخدم **GlassKit** (`lib/ui`)، مكتبة واجهات فورية (immediate mode):

```zig
const std = @import("std");
const ui = @import("ui");

pub const App = struct {
    count: u32 = 0,

    pub const window = ui.client.Options{ .title = "مرحباً", .width = 420, .height = 260 };

    pub fn init(allocator: std.mem.Allocator, u: *ui.Ui) !App {
        _ = allocator;
        _ = u;
        return .{};
    }

    pub fn frame(self: *App, u: *ui.Ui) void {
        u.clear(u.theme.window_bg);
        u.text(ui.Rect.init(24, 20, 372, 32), "أهلاً بك في Zen", .{ .size = 22, .weight = .bold });
        if (u.button("click", ui.Rect.init(24, 160, 120, 32), "اضغط هنا", .{ .style = .primary }))
            self.count += 1;
    }
};
```

```zig
// main.zig
pub fn main() !void { try @import("ui").run(@import("app.zig").App); }
```

العناصر المتاحة: أزرار، مفاتيح تبديل، مربعات اختيار، منزلقات، قوائم منبثقة،
حقول نص (مع التحديد والحافظة وكلمات المرور)، جداول قابلة للترتيب، تمرير،
شريط جانبي، وكل أدوات الرسم في `lib/gfx` (مسارات، تدرجات، زجاج).

دوال اختيارية: `menu` و `onMenu` لشريط القوائم، `shouldClose` و `shouldQuit`
للسؤال عن التغييرات غير المحفوظة، `openDocuments` لاستقبال الملفات من Finder
أو الأمر `open`، و `timeoutMs` للتحديث الدوري.

### حزمة التطبيق

```
HelloZen.app/Contents/Info.conf           المعرّف والاسم والإصدار والأيقونة
HelloZen.app/Contents/Entitlements.conf   الصلاحيات، واحدة في كل سطر
HelloZen.app/Contents/Bin/HelloZen        البرنامج
```

ضع الحزمة في `/Applications` لتظهر في Spotlight و Finder.

### الصلاحيات (Entitlements)

| الصلاحية | ما تمنحه |
|---|---|
| `com.zen.security.app-sandbox` | العمل داخل حاوية: `~/Library/Containers/<id>/Data` تصبح المجلد الرئيسي |
| `com.zen.security.files.documents.read-write` (أو `.read-only`) | مجلد المستندات |
| `com.zen.security.files.downloads.read-write` | مجلد التنزيلات |
| `com.zen.security.files.pictures.read-write` و `.music.` و `.movies.` | تلك المجلدات |
| `com.zen.security.files.user-selected.read-only` | الملفات التي يفتحها المستخدم بنفسه |
| `com.zen.security.network.client` | الشبكة: `tcp:` و `udp:` و `dns:` |
| `com.zen.security.cs.allow-spawn` | تشغيل برامج مساعدة |

### التوقيع الرقمي

لا يشغّل النظام إلا التطبيقات الموقّعة بمفتاح موثوق، أو التطبيقات التي وافق
عليها المستخدم صراحةً في `/etc/zen/gatekeeper.allow`:

```sh
zig build tools
zig-out/tools/codesign keygen my.key my.pub
zig-out/tools/codesign sign my.key HelloZen.app
zig-out/tools/codesign verify my.pub HelloZen.app
```

### "كل شيء عنوان URL"

استخدم `zen.io` لفتح العناوين (`open` و `read` و `write` و `mmap` و `poll`
و `readUrl` و `transact`)، فتعمل الشيفرة نفسها على Zen وفي النسخة المستضافة:

```zig
const zen = @import("zen");
const apps = try zen.io.readUrl(allocator, "launch:apps", 1 << 20);
```

ولكتابة خدمة جديدة (مخطط خاص بك) استخدم `zen.server.Server.register("myscheme")`.
البروتوكول موصوف في `lib/abi/scheme.zig`.

## 8. الأمان باختصار

- **المستخدمون:** `/etc/passwd` و `/etc/group` و `/etc/shadow` (Argon2id).
  أعضاء مجموعة `admin` يستطيعون استخدام `sudo`.
- **الصلاحيات:** كل خادم مخطط يتحقق من هوية المستدعي التي ترفقها النواة
  بكل طلب.
- **الحاويات:** التطبيق المعزول لا يرى إلا حاويته والمجلدات التي تمنحها
  صلاحياته، وقيود العزل لا تُرفع أبداً، بل تزداد صرامة فقط، وتنتقل إلى البرامج
  التي يشغّلها.
- **Gatekeeper:** تحقق من SHA-256 لكل ملف في الحزمة وتوقيع Ed25519 قبل التشغيل.

## 9. البناء والاختبار

```sh
zig build            # كل البرامج لـ riscv64
zig build test       # الاختبارات
zig build image      # صورة القرص (zig-out/zen.img)
zig build hosted     # النسخة المستضافة و Dockerfile
python3 hosted/smoke_test.py --timeout 60   # اختبار آلي: الدخول وسطح المكتب
```

هيكل المستودع:

| المجلد | المحتوى |
|---|---|
| `kernel/` | النواة المصغّرة (غير مكتملة) |
| `servers/` | الخدمات: init و launchd و windowserver و netd و fsd … |
| `drivers/` | تعريفات virtio |
| `apps/` | تطبيقات سطح المكتب |
| `userland/` | الصدفة و zbox و sudo و cc و open و zenfetch |
| `lib/` | ABI و libzen و gfx و GlassKit و الأيقونات والشبكة |
| `hosted/` | vncd وعميل المتصفح و Docker |
| `tools/` | mkimage و codesign و zen-hosted |
