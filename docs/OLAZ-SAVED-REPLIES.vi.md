# Tin nhắn mẫu và lệnh nhắn nhanh

## Tạo và quản lý mẫu

Trong hội thoại Zalo, mở **+ → Tin nhắn mẫu → Xem và quản lý mẫu…**. Cũng có thể mở **Cài đặt → Tin nhắn mẫu**.

Chọn **Thêm mẫu**, nhập:

- Tên mẫu: ví dụ `Địa chỉ cửa hàng`.
- Lệnh tự tạo từ tên: `Địa chỉ cửa hàng` → `/dia-chi-cua-hang`. Bạn có thể sửa thành `/dia-chi` hoặc lệnh khác.
- Nội dung: địa chỉ và thông tin thực tế muốn gửi cho khách. Có thể nhập nhiều dòng.

Mẫu không có nội dung cửa hàng cài sẵn để tránh gửi nhầm thông tin. Mỗi tài khoản Zalo có danh sách riêng, tối đa 300 mẫu đang dùng. Lệnh được chuẩn hóa thành chữ thường không dấu, cho phép chữ, số, dấu `-` và `_`, dài 1–40 ký tự. `/Địa-Chỉ` được lưu thành `/dia-chi`. Hai mẫu đang dùng trong cùng tài khoản không được trùng lệnh. Nội dung tối đa 8.000 ký tự.

Có thể tìm theo lệnh, tên hoặc nội dung; sửa mẫu; gỡ mẫu và bật **Hiện mẫu đã gỡ** để khôi phục. Nếu đã tạo mẫu khác dùng lại lệnh cũ, đổi lệnh mẫu mới trước khi khôi phục.

Trong lúc tạo mẫu mới, lệnh tiếp tục đổi theo tên đến khi bạn sửa lệnh thủ công. Sau đó app giữ nguyên lệnh bạn nhập. Nút **Tạo lại từ tên** tạo gợi ý mới và bật lại chế độ tự tạo. Khi gợi ý bị trùng, app thêm `-2`, `-3`… trong giới hạn 40 ký tự. Mở sửa một mẫu đã lưu sẽ giữ lệnh hiện có; bấm Tạo lại từ tên nếu muốn đổi theo tên mới.

## Dùng lệnh trong ô soạn

1. Gõ `/` để xem tối đa tám gợi ý, hoặc nhập `/dia-chi` để lọc.
2. Dùng ↑/↓ chọn mẫu; **Enter**, **Tab** hoặc nhấp vào mẫu để chèn nội dung.
3. Kiểm tra nội dung trong ô soạn, sau đó gửi bằng thao tác gửi thông thường.

Lần Enter chọn mẫu chỉ chèn nội dung, chưa gửi. Nút gửi cũng chèn mẫu đang chọn trước nếu danh sách gợi ý còn mở. **Esc** đóng gợi ý. **Shift/Option + Enter** giữ chức năng xuống dòng. Khi đang ghép dấu bằng bộ gõ, phím xác nhận không chọn mẫu hoặc gửi tin.

Lệnh được nhận ở đầu ô soạn, đầu dòng hoặc sau khoảng trắng, tại vị trí con trỏ. Khi chọn mẫu, Olaz thay phần lệnh và giữ nội dung còn lại. URL như `https://example.com/dia-chi` và đường dẫn như `/Users/name` không được hiểu là lệnh mẫu. Một lệnh chưa có mẫu phù hợp vẫn là văn bản thông thường.

Việc chèn dùng cơ chế soạn văn bản native: hỗ trợ Undo và giữ vị trí các thẻ `@nhắc tên` còn lại. Tin nhắn mẫu chỉ là văn bản, không tự đánh dấu người nhận bằng cú pháp `@` trong nội dung mẫu và không tự gọi AI/MCP.

## Dùng từ menu +

Menu **+ → Tin nhắn mẫu** hiển thị tối đa tám mẫu đầu tiên theo lệnh. Chọn mẫu để chèn tại con trỏ hoặc thay phần văn bản đang chọn. Nếu đang nhập một lệnh `/...`, phần lệnh đó được thay bằng nội dung mẫu.

**Xem và quản lý mẫu…** cho phép tìm mọi mẫu, xem nội dung và chọn **Chèn vào ô soạn**. **Lưu nội dung đang soạn…** dùng bản nháp làm nội dung mẫu mới; vẫn cần nhập tên/lệnh và bấm Lưu mẫu.

Tạo, sửa, gỡ, khôi phục và chèn mẫu không gửi tin nhắn. Nếu tài khoản/hội thoại thay đổi hoặc bộ gõ còn ghép ký tự, Olaz không chèn vào ngữ cảnh cũ.

## Lưu dữ liệu

Mẫu được lưu cục bộ tại `~/Library/Application Support/Olaz/SavedReplies/replies.json`, tách với dữ liệu Zalo và cấu hình AI. Thư mục mới có quyền 700, tệp có quyền 600. Bản này chưa đồng bộ mẫu giữa các máy.

Nếu không đọc được tệp cũ, Olaz báo lỗi và ngăn ghi đè. Gỡ mẫu là thao tác có thể khôi phục, không xóa vĩnh viễn nội dung khỏi tệp. Dữ liệu mẫu không được đưa vào prompt AI chỉ vì đã lưu; nội dung có thể trở thành một phần hội thoại khi người dùng thực sự gửi tin.

## Kiểm tra bản triển khai

- 506 kiểm thử trong 64 suites đã thành công, gồm 12 kiểm thử mới cho tin nhắn mẫu.
- Đã kiểm tra giao diện thật: tạo/sửa mẫu, lưu qua lần khởi động lại, gợi ý lệnh, Enter chèn mà chưa gửi, Undo, chèn từ menu +, gỡ và khôi phục mẫu.
- Đã mở bản đóng gói `build/Olaz.app`. Nội dung thử đã được xóa khỏi ô soạn; mẫu thử đã được gỡ khỏi danh sách đang dùng. Không thực hiện gửi tin nhắn Zalo trong kiểm tra này.

Cập nhật tự tạo lệnh: đã chạy thành công 14 kiểm thử SavedReplyTests và kiểm tra form thật với tên tiếng Việt, chỉnh lệnh thủ công rồi đổi tên, Tạo lại từ tên và tự thêm hậu tố khi trùng. Form thử được hủy, không lưu thêm mẫu hoặc gửi tin nhắn.
