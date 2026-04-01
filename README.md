# init-server



```bash
# 1. Copy key to root (using Hetzner's root password)
ssh-copy-id root@46.225.156.185

# 2. Run the init script (it creates user oz + copies keys)
ssh root@46.225.156.185
bash <(curl -fsSL https://raw.githubusercontent.com/0OZ/init-server/main/init.sh)

# 3. Test the new user
ssh oz@46.225.156.185
```