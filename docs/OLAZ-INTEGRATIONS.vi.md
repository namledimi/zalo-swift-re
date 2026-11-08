# Hướng dẫn dùng Olaz với MCP và công việc

Cập nhật: 08/11/2026. Tài liệu đi cùng bản triển khai trong mã nguồn. Không nhập mật khẩu, Client Secret hoặc token vào cuộc trò chuyện hỗ trợ.

Ví dụ theo thông tin người dùng: [DIMI Book và phạm vi Facebook đầy đủ](OLAZ-DIMIBOOK-FACEBOOK.vi.md), gồm cấu hình `dimibook.com`, kết quả kiểm tra HTTP 401 và các bước xác minh còn thiếu.

## 1. Bắt đầu từ menu Plugin

Trong thanh bên chọn **Plugin**. Các màn hình:

| Màn hình | Dùng để làm gì |
| --- | --- |
| Kết nối MCP | Thêm nguồn, đăng nhập, kiểm tra công cụ, chọn quyền |
| Trợ lý công việc | Hỏi AI trực tiếp, xem công cụ thực sự được gọi, chèn câu trả lời vào bản nháp Zalo |
| Sản phẩm và báo giá | Tra sản phẩm từ MCP, xem giá/ảnh từ nguồn, chèn báo giá, lập đơn nháp |
| Khách hàng và công việc | Lưu nhu cầu, giai đoạn bán hàng, lịch liên hệ lại, xem đơn nháp |
| Kho hướng dẫn | Nạp, tìm và gỡ tài liệu văn bản cho AI |

AI cần có Claude Code hoặc Codex đã đăng nhập trên Mac. Cài đặt → AI cho phép chọn công cụ, đường dẫn, mô hình và hướng dẫn. Chat trực tiếp với trợ lý không phụ thuộc công tắc tự trả lời Zalo.

## 2. Kết nối WordPress

### Chuẩn bị trên website

1. Website cần HTTPS và plugin **MCP Adapter** đang bật. Đây là plugin WordPress cung cấp MCP; URL trang chủ hoặc REST API thông thường chưa phải server MCP.
2. Tài khoản WordPress phải có quyền đọc/thực thi abilities cần dùng. Plugin hoặc mã trên website phải đăng ký và công khai những abilities đó.
3. Trong quản trị WordPress, vào **Users → Profile → Application Passwords**, tạo mật khẩu ứng dụng dành cho Olaz. Thao tác này do chủ website thực hiện. Dùng username WordPress và Application Password; không dùng mật khẩu đăng nhập tài khoản.

### Cấu hình trong Olaz

1. Plugin → Kết nối MCP → **Thêm kết nối… → WordPress**.
2. Đặt tên dễ nhận biết, ví dụ `Website cửa hàng`.
3. Nhập URL website, ví dụ `https://shop.example` hoặc `https://example.com/cua-hang`, rồi chọn **Tạo endpoint**.
4. Kiểm tra địa chỉ được tạo. Với ví dụ thứ hai, endpoint là:

   `https://example.com/cua-hang/wp-json/mcp/mcp-adapter-default-server`

5. Xác thực: **Tên đăng nhập / mật khẩu (HTTP Basic)**. Nhập username và Application Password trực tiếp trong app.
6. Lưu rồi chọn **Kiểm tra và tải công cụ**. Kết nối mới bắt đầu ở trạng thái tắt.
7. Chọn các công cụ cần thiết. Adapter mặc định thường cung cấp:

   - `mcp-adapter-discover-abilities`: tìm abilities được công khai.
   - `mcp-adapter-get-ability-info`: đọc schema của ability.
   - `mcp-adapter-execute-ability`: thực thi ability.

8. Mở **Quyền abilities WordPress**, tải danh sách và chọn đúng các abilities được phép. Olaz đọc thêm schema/metadata cho abilities đã chọn. Chọn công cụ execute mà chưa chọn ability sẽ không cho thực thi.
9. Bật **Cho trợ lý AI dùng kết nối này**.
10. Vào Trợ lý công việc, chọn nguồn và đặt một câu hỏi đọc dữ liệu. Xem tên công cụ trong câu trả lời. Không dùng kết quả “đã lưu kết nối” thay cho kiểm tra thật.

Website có custom MCP server có thể dùng URL và tên công cụ khác. Giữ endpoint do quản trị website cung cấp. Olaz không tự cài plugin hay sửa website.

## 3. Kết nối WooCommerce

Làm tương tự WordPress nhưng chọn mẫu **WooCommerce**. Mẫu này dùng MCP Adapter và WordPress Application Password. **Consumer Key/Secret của WooCommerce REST API không dùng để đăng nhập endpoint MCP Adapter này.**

Khả năng phụ thuộc phiên bản WooCommerce và các abilities website cung cấp. Tài liệu WooCommerce hiện mô tả phần này là developer preview. Không giả định có mọi công cụ tạo đơn, kiểm tra kho hoặc hoàn tiền.

Một ability đọc sản phẩm trong tài liệu hiện tại là `woocommerce/products-query`. Nếu website trả về ability này:

1. Cấp công cụ discovery, info, execute và cấp riêng ability đọc sản phẩm.
2. Plugin → Sản phẩm và báo giá → chọn nguồn → tải công cụ.
3. Chọn `mcp-adapter-execute-ability`, rồi chọn ability đọc sản phẩm.
4. Mở phần tham số JSON. Nhập **parameters của ability**, theo schema website trả về. Olaz tự bọc `ability_name` và `parameters`; không cần tự bọc lần nữa.
5. Tra sản phẩm. Có thể cần đặt phân trang/bộ lọc theo schema nguồn. Bộ lọc giá trong Olaz chỉ lọc trang sản phẩm đã tải, chưa quét toàn bộ kho.

Màn hình này hỗ trợ các dạng phản hồi thông dụng: danh sách trực tiếp hoặc `items/products/results`, giá `minPrice/maxPrice`, WooCommerce `price` và Store API `prices`. Nếu nguồn trả cấu trúc riêng, xem dữ liệu trong Kết nối hoặc hỏi Trợ lý công việc; có thể cần bổ sung bộ chuẩn hóa cho nguồn đó.

Đơn lập ở Olaz hiện là **đơn nháp nội bộ**. Lưu/duyệt nội bộ không tạo đơn trên WooCommerce. Tính năng ghi đơn trực tiếp và đồng bộ hai chiều cần triển khai theo server thực tế.

## 4. Facebook và Meta

### Quảng cáo Meta Ads

Chọn **Facebook · Meta Ads**. Mẫu điền sẵn `https://mcp.facebook.com/ads` và OAuth. Cần thông tin client được Meta chấp nhận, tài khoản có quyền dữ liệu quảng cáo và callback phù hợp.

Trong lần thử trước, Meta từ chối đăng ký client tự động của Olaz. Vì vậy chỉ nhập URL rồi bấm đăng nhập chưa đủ. Cấu hình App ID/Client ID hợp lệ và thông tin OAuth nâng cao theo nhà cung cấp; không tạo App ID giả hoặc dùng Client Secret của ứng dụng khác.

Nếu nhà cung cấp cấp token MCP hợp lệ, có thể chọn kiểu xác thực tương ứng thay vì OAuth. Không khẳng định mọi Facebook Graph token đều dùng được với endpoint MCP.

### Fanpage, bình luận, Messenger

Chọn **Facebook · Page / Messenger** rồi nhập URL của MCP server thực sự cung cấp các công cụ này. Không dùng endpoint Meta Ads để thay cho hộp thư Fanpage.

Olaz đã có phần cấu hình và gọi công cụ MCP tùy chỉnh. Server xử lý Graph API, quyền Page/Messenger và webhook phải được cung cấp riêng. Tự động nhận/trả lời tin Facebook và hợp nhất Inbox chưa có trong đợt triển khai này.

## 5. OAuth và callback

Không có một callback dùng được cho mọi nhà cung cấp. Callback phải khớp cấu hình client và quy định server:

- Local: `http://127.0.0.1:8765/callback`, chỉ khi nhà cung cấp chấp nhận loopback cho ứng dụng desktop.
- HTTPS: dùng domain hoặc tunnel HTTPS đã được cấu hình chuyển tiếp về listener Olaz. Đăng ký **đúng URL đầy đủ** và nhập cùng URL vào OAuth nâng cao trong Olaz.

Olaz chỉ mở listener callback trong lúc đăng nhập. URL tunnel tạm có thể thay đổi hoặc hết hiệu lực khi tiến trình tunnel dừng; tài liệu không gắn cứng URL cũ làm cấu hình dài hạn. Tunnel chỉ giải quyết đường dẫn callback, không thay App ID, scope hoặc quyền của nhà cung cấp.

## 6. Hỏi trợ lý và đưa nội dung sang Zalo

1. Plugin → Trợ lý công việc.
2. Chọn nguồn đang bật, đã xác thực và cấp quyền.
3. Hỏi cụ thể, ví dụ: “Tra ba mẫu hoa đang bán trong khoảng giá 300.000 đến 500.000 đồng”.
4. Đọc câu trả lời, tên công cụ được gọi và lỗi nếu có. Nếu không có tên công cụ, chưa thể coi câu trả lời đó là tra cứu mới từ MCP.
5. Chọn hội thoại nhận và bấm **Chèn vào ô soạn Zalo**. Nội dung được nối vào bản nháp đang có; kiểm tra và gửi bằng thao tác gửi Zalo.

Trợ lý công việc chỉ được cấp các công cụ đọc đã phân loại và được bạn chọn. Annotations là gợi ý từ server; tài khoản ở nguồn vẫn nên có đúng quyền cần dùng. Thay nguồn hoặc cấu hình làm mới phiên trợ lý. Lịch sử trợ lý hiện giữ trong bộ nhớ và được xóa khi đổi tài khoản/thoát app.

## 7. Sản phẩm, ảnh và báo giá

Với nguồn công khai trực tiếp `search_products`, chọn công cụ này và nhập từ khóa nếu schema có `query/search/s`. Nếu dùng bộ lọc dạng đối tượng, nhập JSON theo schema rồi để từ khóa trống. Ví dụ riêng cho Hoa tươi đã được xác minh trước:

```json
{"status":"ACTIVE"}
```

Thông tin trên thẻ lấy từ MCP: tên, SKU, giá/tiền tệ, thời điểm đọc và nguồn. Không có giá thì hiện “Chưa có giá”; không rõ tiền tệ thì ghi rõ. Nút tải chi tiết hỗ trợ `get_product` với ID phù hợp schema.

- **Chèn báo giá**: nối nội dung vào ô soạn, chưa gửi.
- **Gửi ảnh…**: mở xem trước và hiện người nhận; chỉ gửi khi xác nhận. Nguồn phải có URL ảnh HTTPS, phản hồi là ảnh và tối đa 10 MB. Nếu thao tác Zalo đang chờ phản hồi, kiểm tra hội thoại trước khi thao tác lại.
- **Lập đơn nháp…**: mở phiếu nội bộ. Giá thấp nhất từ nguồn là giá tham khảo, cần kiểm tra lại trước khi duyệt.

## 8. AI theo từng hội thoại

Mở phần Thông tin hội thoại → AI cho hội thoại này:

- Bật/tắt riêng; công tắc AI toàn bộ vẫn ở Cài đặt AI.
- Theo chế độ chung, Soạn để duyệt hoặc Tự động gửi riêng.
- Tạm dừng 15 phút; tiếp tục ngay hoặc tự tiếp tục khi hết hạn và Olaz đang chạy. Khi mở lại app, mốc tạm dừng được đọc lại.
- Khi bạn gửi văn bản thủ công, có thể giữ AI hoặc tạm dừng 15/60 phút. Tùy chọn này cũng áp dụng cho ảnh gửi từ màn hình Sản phẩm; các luồng gửi tệp/sticker khác chưa có tùy chọn tiếp quản riêng.
- Chọn nguồn MCP riêng. Bỏ tất cả nguồn nghĩa là AI không được cấp MCP cho hội thoại đó. “Dùng tất cả nguồn đang bật” trở về kế thừa.

Chỉ xử lý tin nhắn văn bản mới sau khi bật/tiếp tục. Đổi chế độ, đổi nguồn, người dùng trả lời hoặc đổi tài khoản sẽ hủy việc đang chờ. Tạm dừng không tạo tác vụ trả lời bù tin cũ.

## 9. Hồ sơ, lịch liên hệ và đơn nháp

Từ Thông tin hội thoại chọn **Hồ sơ khách và lịch liên hệ…**, hoặc vào Plugin → Khách hàng và công việc. Lưu nhu cầu, ngân sách, dịp tặng, giai đoạn, ghi chú và lịch liên hệ/ngày giao. Danh sách ưu tiên lịch sớm; việc đến hạn có màu nổi bật. “Đã liên hệ” xóa mốc nhắc, không gửi tin cho khách. Bản đầu chưa có thông báo hệ thống khi app đóng.

Đơn nháp có thông tin người nhận, số lượng, đơn giá, tiền tệ, lịch giao và lời chúc. Để duyệt nội bộ cần đủ giá/tiền tệ và thông tin người nhận. Chỉnh nội dung sẽ bỏ trạng thái duyệt cũ. Có thể sao chép hoặc xuất JSON; file xuất chứa thông tin khách nên lưu ở vị trí phù hợp.

Dữ liệu công việc nằm trong `Application Support/Olaz/Work/data.json`, tách theo ID tài khoản Zalo và hội thoại. Quyền thư mục 700, file 600. Không đọc được file cũ sẽ báo lỗi và ngăn ghi đè.

## 10. Lưu đăng nhập và Keychain

Token OAuth và Client Secret OAuth dùng Keychain, có cache trong phiên để tránh đọc lặp. Header do bạn nhập, bao gồm Basic/API key, hiện nằm trong cấu hình Plugin riêng của người dùng với quyền file 600; đây chưa phải kho mã hóa riêng cho mọi loại secret. Không chia sẻ file cấu hình.

Bản build ad-hoc có thể khiến macOS hỏi lại quyền Keychain sau khi cập nhật binary. Khắc phục lâu dài cần ký bằng cùng danh tính chứng chỉ. Không tắt Keychain hoặc nhập mật khẩu macOS vào chat để xử lý hộp thoại. Chủ máy tự thao tác hộp thoại hệ thống.

## 11. Xử lý lỗi nhanh

| Hiện tượng | Kiểm tra |
| --- | --- |
| 401 / cần xác thực | Kiểu auth, Application Password/token, trạng thái đăng nhập |
| 403 | Quyền tài khoản, ability có được công khai không, chính sách server |
| 404 | Endpoint MCP, thư mục con WordPress, plugin Adapter đã bật chưa |
| OAuth 400 invalid_client | Client ID được chấp nhận, đăng ký client và callback đúng |
| Có kết nối nhưng AI không tra | Đã bật nguồn/cấp công cụ chưa; hội thoại có chọn nguồn không; xem công cụ thực sự gọi |
| execute-ability bị chặn | Cấp đúng tên ability trong mục WordPress; không chỉ cấp tool bên ngoài |
| Có sản phẩm nhưng không có ảnh | Nguồn chưa trả URL ảnh, thử chi tiết; Olaz không tự bịa/tìm ảnh thay thế |
| Không chuẩn hóa được sản phẩm | Xem JSON gốc; nguồn có thể dùng cấu trúc khác |
| Không lưu hồ sơ | Kiểm tra thông báo lỗi và quyền thư mục; không xóa file cũ khi chưa sao lưu |

## 12. Tài liệu gốc

- [WordPress: cấu hình cho chủ website](https://github.com/WordPress/mcp-adapter/blob/trunk/docs/getting-started/site-owners.md)
- [WordPress: default server và abilities](https://github.com/WordPress/mcp-adapter/blob/trunk/docs/guides/default-server.md)
- [WooCommerce: MCP và Application Password](https://github.com/woocommerce/woocommerce/blob/trunk/docs/features/mcp/README.md)
- [Đặc tả và phạm vi phát triển Olaz](OLAZ-WORKSPACE-PLAN.vi.md)
