# Kiến trúc mạng của WQTerm (Phase 1 — Network & Pairing)

Tài liệu này ghi lại **kiến trúc thực tế** sau khi rà soát toàn bộ source, để
không ai "sửa IP cho vừa test" hoặc thêm listener giả.

## 1. WQTerm KHÔNG tạo tunnel — nó là client

Rà soát toàn bộ repo (157 file, `git log -S NEPacketTunnelProvider`):

* **Không có** `NEPacketTunnelProvider` / `NETunnelProviderManager` /
  `NEVPNManager` / `NEPacketTunnelNetworkSettings` / `NEIPv4Settings`.
* `project.yml` chỉ khai báo **một** target `WQTerm` (application). Không có
  Network Extension target, không có `.appex` được nhúng.
* `WQTerm.entitlements` không có `packet-tunnel-provider` hay
  `com.apple.developer.networking.networkextension`.

⇒ Tunnel `utun*` trên thiết bị do **ứng dụng khác** cung cấp (LocalDevVPN của
StikDebug hoặc một app VPN cá nhân). WQTerm chỉ **đọc** địa chỉ của tunnel đó rồi
bind TCP listener lên chính địa chỉ ấy.

### Vì sao không thêm Network Extension target?

Thêm provider là thay đổi kiến trúc lớn (cần entitlement được Apple cấp, cần
`packet-tunnel-provider` trong provisioning profile, cần thiết kế routing và
lifetime của tunnel). Phase 1 yêu cầu "nếu kiến trúc tunnel hiện tại không cho
phép bind/routing theo mô hình dự kiến, phải xác định nguyên nhân và đề xuất
kiến trúc tương thích thay vì vá giả". Nguyên nhân thật **không phải** thiếu
provider — mà là app đang **giả định sai địa chỉ tunnel**. Xem mục 2.

Nếu sau này cần tunnel riêng (không phụ thuộc app ngoài), đó là Phase mới: cần
target `.appex` loại `packet-tunnel-provider`, `NEProvider` chạy trong tiến
trình riêng, và `NETunnelProviderManager` cấu hình từ app chính. Khi đó
`NetworkUtils` vẫn dùng được nguyên vẹn vì nó chỉ đọc interface.

## 2. Root cause: `10.7.0.1` là giá trị hardcode, không phải IP thực

Trước Phase 1:

* `TunnelConfiguration.defaultAddress = "10.7.0.1"` — chuỗi hardcode duy nhất,
  được dùng như **điều kiện duy nhất** để kết luận "VPN sẵn sàng".
* `NetworkUtils.currentTunnelInfo()` chỉ trả `.isReady = true` khi tìm thấy đúng
  `10.7.0.1` trên một interface `utun*/ppp*/ipsec*`.
* Topology thật của thiết bị bị lỗi:
  ```
  ipsec4 = 28.215.155.104
  ipsec5 = 28.215.155.104
  utun4  = 10.7.1.1
  (không có 10.7.0.1)
  ```

⇒ `isLocalDevVPNActive` **luôn false**. Hệ quả dây chuyền:

1. `PairingManager.beginPairing()` return `false` ngay từ bước đầu.
2. `startHost()` không bao giờ chạy → không có `NWListener`.
3. Không có `listener.service` → Bonjour không quảng bá → "chưa gọi startHost()".
4. Chẩn đoán hiển thị "TCP listener: STOPPED".

Bốn triệu chứng, **một nguyên nhân**. Không phải listener hỏng, không phải
Bonjour hỏng.

### Vì sao không đổi 10.7.0.1 → 10.7.1.1 một cách mù quáng

`10.7.1.1/24` với peer `10.7.1.2` là topology point-to-point hợp lệ — nhưng
không có gì bảo đảm nó là tunnel mà pairing cần (thiết bị có thể có nhiều
utun; địa chỉ có thể đổi giữa các lần bật VPN; peer có thể không phải host
đối tác). Đổi cứng sẽ "sửa" đúng một thiết bị và hỏng thiết bị khác.

Cách làm hiện tại: **phát hiện + xác nhận**. Xem mục 3.

## 3. Mô hình hai địa chỉ (không tự đổi IP)

`TunnelConfiguration` tách đôi:

| Khái niệm | Ý nghĩa | Ai đặt |
|---|---|---|
| `preferredAddress` (mặc định `10.7.0.1`) | Giá trị **mong đợi** | Người dùng, trong Cài đặt |
| `confirmedAddress` | Địa chỉ **thực tế** đã xác nhận | Người dùng, sau discovery |

Thứ tự `TunnelResolver` dùng để quyết định:

1. `confirmedAddress` nếu nó nằm trên tunnel hợp lệ.
2. `preferredAddress` nếu nó nằm trên tunnel hợp lệ.
3. Không khớp ⇒ `.candidateAvailable` (UI đề xuất, chờ xác nhận).
4. Tunnel có nhưng địa chỉ không dùng được ⇒ `.noUsableAddress` (kèm lý do từng cái).
5. Không có interface tunnel ⇒ `.noTunnelInterface`.

Điều kiện để một địa chỉ được coi là điểm cuối tunnel (`InterfaceSnapshot.tunnelRejection`):

* tên interface thuộc `utun*`, `ppp*`, `ipsec*`;
* IPv4, **không** loopback (`127/8`), **không** link-local (`169.254/16`), **không** `0.0.0.0`;
* interface đang `UP` **và** `RUNNING`;
* có cờ `IFF_POINTOPOINT` hoặc có peer address;
* địa chỉ là **riêng**: RFC1918 (`10/8`, `172.16/12`, `192.168/16`) hoặc CGNAT (`100.64/10`).

Vì vậy `ipsec4 = 28.215.155.104` bị loại với lý do tường minh
("không phải địa chỉ riêng"), chứ không bị "coi là VPN".

## 4. Listener: vòng đời và bất biến

`TunnelListenerManager` (Network.framework) + `ListenerStateMachine` (logic thuần):

```
STOPPED → INITIALIZING → WAITING_FOR_TUNNEL → VALIDATING_ADDRESS
        → STARTING_LISTENER → LISTENING → ACCEPTING_CONNECTIONS
nhánh: FAILED, RECOVERING, STOPPING
```

Bất biến đã cưỡng chế bằng code:

* `.listening` **chỉ** sau `NWListener.State.ready` (state machine từ chối mọi
  transition tắt, xem `ListenerState.allowedNext`).
* Bind vào địa chỉ **đã xác minh**; địa chỉ phải còn nằm trên interface tunnel
  UP+RUNNING ngay trước khi bind (`validateAndBind`).
* `.waiting(NWError)` được **map thành lỗi có mã**; hết `listenTimeout` (6s) vẫn
  chưa `.ready` ⇒ FAILED. Đây chính là lỗi cũ: `.waiting` kẹt vĩnh viễn vì bind
  vào `10.7.0.1` không tồn tại (`EADDRNOTAVAIL`).
* Retry tối đa `maxAttempts` (3), backoff tuyến tính; không bao giờ vô hạn.
* `generation` tăng mỗi lần start/stop ⇒ callback của listener cũ bị bỏ qua.
* `cancelListenerObjects()` luôn `cancel()` rồi bỏ tham chiếu ⇒ không tái sử dụng
  listener đã cancel. `currentListener` chỉ trả về khi state đã `.listening`.
* Tunnel đổi địa chỉ ⇒ `handleTunnelChange()` restart listener.

## 5. Bonjour: chỉ sau listener ready

`BonjourAdvertiser`:

* `attach(to:port:identifier:authTag:)` **từ chối** khi listener chưa `.ready`
  hoặc port = 0.
* `detach()` được gọi ở mọi nhánh dừng/khởi động lại (`.failed`, `.recovering`,
  `.stopping`, `.stopped`, và trước khi restart).
* `verifyDiscovery(timeout:)` browse thật qua `NWBrowser` và trả về số kết quả;
  không giả định multicast đi xuyên VPN — kết quả rỗng là thông tin thật.
* Service type/name và `NSBonjourServices` trong `Info.plist` khớp nhau:
  `_remotepairing-pairable-host._tcp`, `_remotepairing._tcp`.

## 6. Handshake: phải hai chiều và có HMAC

Không còn "parse được dictionary ⇒ paired". Giao thức (`PairingHandshake.swift`):

1. TCP ready → host gửi `{"type":"challenge","value":"<base64 32B>"}` (có framing).
2. Thiết bị gửi `{"type":"hello","record":{PairingData, AltIRK/DeviceUDID,...}}`.
3. Thiết bị gửi `{"type":"response","hmac":"base64(HMAC-SHA256(PairingData, challenge))"}`.
4. Host so sánh **constant-time**. Chỉ khớp mới `handshakeVerified = true`.

Khung: `[UInt32 big-endian length][payload]`, tối đa 1 MiB. Nhờ vậy biết chắc khi
nào có đủ message, và message sai thứ tự bị từ chối.

Mỗi kết nối là một `HandshakeSession` mới. Kết nối lỗi bị `cancel()` + xoá khỏi
danh sách ngay ⇒ không tái sử dụng, tránh `NWError -65569 DefunctConnection`
(`EBADF`).

## 7. Chẩn đoán 7 bước

| # | Bước | PASS khi | FAIL/WARNING khi |
|---|---|---|---|
| 1 | LocalDevVPN | có địa chỉ tunnel đã xác minh | không có interface / không địa chỉ dùng được / **warning** khi có ứng viên chờ xác nhận |
| 2 | Tunnel address | địa chỉ + CIDR + flags UP/RUNNING/P2P | **warning** nếu trùng IP interface khác |
| 3 | Tunnel routing | TCP tới relay port thành công | **warning** nếu relay không chạy (không chứng minh tunnel hỏng) |
| 4 | TCP listener | `.listening` + probe TCP OK | FAIL nếu state chưa ready, kèm mã lỗi listener |
| 5 | Bonjour | `isPublished` + port thật | FAIL kèm mã `E_BONJOUR*` |
| 6 | Discovery | browse thấy ≥ 1 service | **warning** `E_DISCOVERY_TIMEOUT` |
| 7 | Pairing handshake | `handshakeVerified` + state `.completed` | FAIL `E_NO_HANDSHAKE` / warning khi đang chờ |

Mỗi bước hiển thị: trạng thái, chi tiết, mã lỗi, thời gian đo, hướng khắc phục.

## 8. Giới hạn đã biết (chưa thể kiểm chứng trong môi trường này)

Những điều **chưa** được kiểm chứng và vì thế **không** được đánh dấu PASS:

* Bind `NWListener` trên `utun` thật: cần thiết bị iOS + LocalDevVPN đang chạy.
  Trên Linux chỉ typecheck được; không có Network.framework.
* Bonjour multicast qua tunnel: hành vi phụ thuộc tunnel, không thể suy đoán.
  `verifyDiscovery()` đo thật và báo WARNING khi không thấy.
* Handshake với thiết bị iOS thật: định dạng `record`/`response` phía thiết bị
  chưa được Apple công bố; host yêu cầu đúng challenge/HMAC và từ chối phần còn lại.
* `xcodebuild` + nhúng `.appex`: không có Xcode trong môi trường này.

## 9. Kiểm thử tự động

```bash
bash scripts/test-core.sh     # 36 test: resolver, state machine, handshake, SHA-256
```

Các test chạy được trên Linux vì phần quyết định (địa chỉ nào hợp lệ, khi nào
LISTENING, khi nào handshake xong) được tách thành module thuần Foundation.
