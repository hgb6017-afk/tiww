# DLS LiteFX V2 — Dopamine RootHide

Bản nâng cấp từ DLSLowRes V1 đã xác nhận hoạt động trên máy của bạn.

## Đã xác nhận
V1 hook `CAMetalLayer setDrawableSize:` hoạt động:
- input 1920x1080
- scale 0.55
- output 1056x594

V2 giữ nguyên phần đó và thêm **Metal draw filter thử nghiệm**.

## Tính năng
- hạ render resolution riêng DLS
- thử tắt draw pass có shader/pipeline mang tên:
  - `shadow`
  - `crowd` / `spectator`
  - `precip` / `rain` / `snow` / `weather`
  - `grass`
  - `bloom`

Không sửa save, account, shop, AI hay network.

## Vì sao gọi là thử nghiệm?
DLS là game release build. Nếu tên pipeline Metal vẫn còn các từ như
`shadow`, `crowd`, `snow`... thì V2 sẽ nhận diện và bỏ draw call.
Nếu FTG strip tên pipeline hoàn toàn, phần filter sẽ không tác dụng;
V2 sẽ ghi log để biết chính xác.

## Cài
1. Build `.deb` bằng GitHub Actions giống bản V1.
2. Cài `.deb` mới. Package ID giữ nguyên `com.openai.dlslowres`,
   nên nó sẽ upgrade bản V1.
3. Respring.
4. Force close DLS rồi mở lại.

V2 tự tạo `Documents/dlslite.txt` mặc định:

```text
scale=55
disable_shadows=1
disable_crowd=1
disable_weather=1
disable_grass=1
disable_bloom=1
```

Muốn chỉ giữ LowRes như V1, đặt tất cả `disable_* = 0`.

## File kiểm tra
Sau khi vào một trận 30–60 giây:

- `Documents/dlslite_drawable.txt`
  - xác nhận resolution scaler.

- `Documents/dlslite_status.txt`
  - số pipeline nhận diện được.
  - số draw call thực sự bị skip.

- `Documents/dlslite_pipelines.txt`
  - danh sách tên pipeline/function Metal mà game tạo.

Nếu `skipped_draws > 0`, filter đang tác dụng thật.
Nếu `skipped_draws = 0`, gửi `dlslite_pipelines.txt` để tinh chỉnh classifier.

## Nếu game crash/đen màn hình
Gỡ tweak hoặc sửa `dlslite.txt` thành:

```text
scale=55
disable_shadows=0
disable_crowd=0
disable_weather=0
disable_grass=0
disable_bloom=0
```

rồi force close/mở lại. Khi đó chỉ còn tính năng LowRes đã xác nhận ổn định.
