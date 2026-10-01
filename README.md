# Web đăng ký lấy số khám Nhi – Sản

```
.github/workflows/deploy.yml   # GitHub Actions tự triển khai lên Pages
public/index.html              # trang bệnh nhân (đăng ký 11:00–15:00)
public/admin.html              # trang bác sĩ
supabase/schema.sql            # chạy 1 lần trong Supabase SQL Editor
```

## Triển khai (làm 1 lần)
1. **Supabase**: SQL Editor → dán `supabase/schema.sql` → Run. Authentication → Users → Add user (tài khoản bác sĩ).
2. **Bật Pages trước**: Settings → Pages → Source = **GitHub Actions** (GitHub tự tạo Environment `github-pages`).
3. **Environment secrets**: Settings → Environments → `github-pages`:
   - *Deployment branches and tags* → **Selected branches** → chỉ cho `main`
   - *Environment secrets* → Add secret:
     - `SUPABASE_URL` = Project URL
     - `SUPABASE_ANON_KEY` = anon public key
   - (Không dùng Repository secrets.)
4. Push lên `main` (hoặc Actions → Deploy → Run workflow). Web chạy tại `https://<user>.github.io/<repo>/`, bác sĩ vào `/admin.html`.

**Không** dùng `service_role` key ở bất kỳ đâu trong repo này. Khóa Supabase được chèn tự động khi build, không cần sửa file.
