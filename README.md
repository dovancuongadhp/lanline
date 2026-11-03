# LanLock

Mở ứng dụng không tắt Wi‑Fi. Bật **Chặn mạng ngoài** khi đang dùng mạng nội bộ, để khỏi bật nhầm Wi‑Fi. Tắt công tắc hoặc thoát bằng Command–Q thì phải dùng mật khẩu hoặc vân tay.

Bảng điều khiển hiện địa chỉ IP của các mạng đang có. Có thể chọn tắt thêm mạng iPhone cắm dây và Bluetooth PAN.

## Cài

Mở `dist/LanLock.dmg`, kéo **LanLock** vào Applications, rồi mở app. Máy Apple Silicon dùng bản này được. Lần đầu có thể hỏi mật khẩu quản trị một lần.

Xóa app trong Applications là gỡ. Phần chạy nền thấy app không còn thì tự dừng và nhả Wi‑Fi.

Đóng cửa sổ chỉ giấu bảng. Icon khiên trên menu bar vẫn ở đó. Chuột phải vào icon để xem IP.

## Gỡ

```bash
sudo ./uninstall.sh
```
