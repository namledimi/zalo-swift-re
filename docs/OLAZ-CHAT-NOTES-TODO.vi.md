# Ghi chú và Todo theo từng hội thoại

## Mở từng phần

- Trong chat, chọn **+ → Ghi chú riêng…** hoặc **+ → Việc cần làm…**. Mỗi mục mở một cửa sổ riêng.
- Hoặc mở **Thông tin hội thoại**, nơi hai phần hiển thị thành hai thẻ độc lập với nền theo giao diện hệ thống và chữ tương phản rõ.
- **Sửa/Thêm** ở thẻ Ghi chú mở vùng soạn thảo ghi chú rộng hơn và đặt con trỏ vào nội dung. Bản xem trước ở thanh bên hiển thị tối đa ba dòng.
- **+ Thêm** ở thẻ Việc cần làm mở danh sách công việc riêng và đặt con trỏ vào ô nhập việc mới. Số cạnh tiêu đề là số việc chưa xong.
- Thẻ công việc hiển thị tối đa hai việc chưa xong, cho phép tích hoàn thành ngay tại đây. Chọn **Mở danh sách việc / Xem tất cả…** để xem đầy đủ. Khi mọi việc đã xong, chọn **Xem việc đã hoàn thành** để mở tab Đã xong.

Dữ liệu gắn với cả tài khoản Zalo và ID hội thoại. Hai tài khoản có hội thoại cùng ID vẫn có dữ liệu riêng. Hội thoại cá nhân, nhóm và Cloud của tôi đều có bảng ghi chú riêng.

## Ghi chú

Nhập văn bản nhiều dòng vào **Ghi chú riêng**. Cửa sổ này chỉ hiển thị ghi chú, vùng soạn thảo lớn và bộ đếm ký tự. Olaz tự lưu trên máy khi chỉnh sửa, tối đa 20.000 ký tự. Lỗi lưu hoặc nội dung không hợp lệ sẽ được báo ngay; nút **Xong** kiểm tra lại việc lưu trước khi đóng bảng. Có thể xóa nội dung để làm trống ghi chú.

Ghi chú ở bảng này độc lập với trường ghi chú trong Hồ sơ khách hàng đã có. Bản cập nhật không ghi đè ghi chú hồ sơ cũ.

## Việc cần làm

1. Nhập tên việc, nhấn Enter hoặc **Thêm**. Tên từ 1 đến 300 ký tự.
2. Tích ô bên cạnh để đánh dấu đã hoàn thành. Chọn tab **Đã xong** để xem hoặc bỏ dấu hoàn thành, đưa việc về tab **Đang làm**.
3. Menu ba chấm của việc → **Sửa…** để đổi nội dung hoặc thêm hạn xử lý.
4. **Gỡ việc** đưa việc vào tab **Đã gỡ**; chọn **Khôi phục** nếu cần. Việc khôi phục giữ nguyên nội dung, hạn và trạng thái hoàn thành.

Ba tab **Đang làm / Đã xong / Đã gỡ** có số lượng riêng. Ô thêm việc luôn nằm phía trên danh sách; khi thêm từ bất kỳ tab nào, Olaz chuyển về Đang làm để hiển thị việc vừa thêm. Cửa sổ công việc không chứa vùng ghi chú và đóng cửa sổ không ghi lại nội dung ghi chú.

Việc chưa xong được xếp trước; các việc có hạn sớm xếp trước những việc còn lại. Hạn đã qua hiện màu nổi bật. Mỗi hội thoại có tối đa 300 việc chưa gỡ, bao gồm việc đã hoàn thành.

Hạn xử lý dùng để theo dõi trong Olaz; bản này chưa gửi thông báo hệ thống khi app đóng. Notes và Todo là dữ liệu làm việc nội bộ: thêm/sửa/đánh dấu không tạo tin nhắn Zalo, không tạo nhắc hẹn chung và không tự đưa nội dung vào AI/MCP.

## Lưu trữ

Dữ liệu nằm trong `~/Library/Application Support/Olaz/Work/data.json`, cùng kho công việc local. Thư mục mới có quyền 700, file 600. Mô hình mới đọc được dữ liệu cũ chưa có Notes/Todo; các hồ sơ và đơn nháp được giữ nguyên. Nếu file cũ lỗi định dạng, app báo lỗi và ngăn ghi đè.

## Sửa giao diện nhắc hẹn

Cửa sổ **Tạo nhắc hẹn** có lề rõ ràng, nội dung cuộn, các mốc thời gian xếp thành hai cột để không tràn ngang. Chọn **Chọn ngày / giờ…** để nhập thời gian khác. Luồng nhắc hẹn Zalo vẫn là thao tác riêng, chỉ thực hiện khi người dùng bấm **Tạo nhắc hẹn** với nội dung hợp lệ.

## Xác minh bản triển khai

- Lần tách thành hai cửa sổ: biên dịch thành công, 11 kiểm thử Notes/Todo và thanh thông tin đạt. Đã kiểm tra app thật: hai thẻ độc lập, vùng ghi chú lớn hơn, cửa sổ công việc không chứa ghi chú, ba tab hiển thị đúng trạng thái/số lượng, cả hai mục trong menu dấu + mở đúng cửa sổ và đúng ô nhập. Không thay đổi nội dung ghi chú hay công việc hiện có khi kiểm tra.
- Lần chỉnh thẻ thanh thông tin trước khi tách cửa sổ: 11 kiểm thử liên quan đến Notes/Todo và kích thước thanh thông tin thành công; không thay đổi cấu trúc dữ liệu lưu. Đã kiểm tra độ vừa của thẻ, nút Sửa đặt con trỏ vào ghi chú, nút Thêm đặt con trỏ vào tên việc và liên kết việc đã hoàn thành bật đúng bộ lọc; giữ nguyên dữ liệu người dùng.
- 515 kiểm thử trong 65 suites thành công ở lần chạy lại; lần đầu dừng do một kiểm thử adapter JavaScript có sẵn bị treo. Có 7 kiểm thử mới cho Notes/Todo, gồm tách tài khoản/hội thoại, lưu trữ, đọc file cũ, lỗi lưu và khôi phục việc đã gỡ.
- Đã kiểm tra giao diện thật: bố cục nhắc hẹn thường/tùy chọn ngày giờ, mở Notes/Todo từ thanh thông tin và dấu +, tự lưu và mở lại ghi chú, thêm Todo, đặt hạn, đánh dấu hoàn thành và danh sách khôi phục.
- Ghi chú thử đã làm trống và Todo thử đã gỡ khỏi danh sách đang dùng. Không gửi tin nhắn hoặc tạo nhắc hẹn Zalo trong kiểm tra.
