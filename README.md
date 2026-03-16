# MTProto
Автоматическое создание и управление портами для MTProto

# 1. Скачать и установить
```bash
sudo curl -fsSL https://raw.githubusercontent.com/androideworld/MTProto/main/mtproto-manager_2.1.sh \
    -o /usr/local/bin/mtproto-manager
```

# 2. Сделать исполняемым
```bash
sudo chmod +x /usr/local/bin/mtproto-manager
```

# 3. Проверка
✅ Должно быть: #!/bin/bash$

```bash
head -1 /usr/local/bin/mtproto-manager | cat -A
```
