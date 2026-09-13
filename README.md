# jackspark.top.server
## server to host vless, nginx, react app and ssh and more



How to set up Vless:
Video
https://www.youtube.com/watch?v=eqYL6P6T9sU

Text tutorial
https://bulianglin.com/archives/nicenamebak.html

key code:
`bash <(curl -Ls https://raw.githubusercontent.com/FranzKafkaYu/x-ui/956bf85bbac978d56c0e319c5fac2d6db7df9564/install.sh) `



Nginx services :

| 项目名称   | 技术栈               | 参考github repo                     | 学习来源              |
| -------- | -------------------- | ---------------------------------- | --------------------- |
| gallery  | HTML + Tailwind CSS  | -                                  | -                     |
| pose     | HTML + JavaScript    | -                                  | -                     |
| monster  | React Web + npm      | React-beginner-tutorial-TeacherEgg | B站：技术蛋老师         |
| chores   | React Native + Expo  | React Native                       | YouTube: freeCodeCamp |
| land     | React Native + THREE | React Native                       | AI studio GEMINI demo |
| guess    | next.js + React Web  |                                    | gemini                |
| tank     | HTML + babylon.js    | -                                  | -                     |

## 项目说明


### gallery
- **技术栈**: HTML + Tailwind CSS
- **描述**: 图片画廊项目
- https://jackspark.top/gallery/


### pose
- **技术栈**: HTML + JavaScript
- **描述**: 姿态相关项目
- https://jackspark.top/pose/


### monster， muji
- **技术栈**: React Web + npm
- **参考项目**: React-beginner-tutorial-TeacherEgg
- **学习资源**: B站 - 技术蛋老师
- https://monster.jackspark.top


### chores， x, todo-like dashboard
- **技术栈**: React Native + Expo
- **参考项目**: React Native Todo
- **学习资源**: YouTube - freeCodeCamp
- https://x.jackspark.top

### land, sim city类的城市建设, skyline builder, lego city, city crafter
- **技术栈**: React Native + THRESS
- **参考项目**: AI studio GEMINI demo
- **学习资源**: [YouTube - freeCodeCamp](https://ai.studio/apps/drive/1LQM38Nqfb26ytMYDMQfERnOwRPvPZCaM)
- https://land.jackspark.top

### guess
- **技术栈**: next.js + React Web
- **参考项目**: GEMINI 
- **学习资源**: N/A. 儿童作画， 然后AI识别出你做的画的问题， 然后上色补全为粘土风格的画
- npm run dev to expose 3000
- https://guess.jackspark.top

### grnr
- **技术栈**: React js
- **参考项目**: gauge repeatability and replicability 学习项目， for Tony
- **学习资源**: NA
- https://grnr.jackspark.top

### dd
- **技术栈**: babylon.js
- **参考项目**: duck-n-drade ， 打水漂的小游戏， for lucas
- **学习资源**: NA
- https://jackspark.top/dd/

### tank
- **技术栈**: babylon.js
- **参考项目**: 坦克大战的小游戏， 炮塔和地盘独立控制， for lucas
- **学习资源**: NA
- https://jackspark.top/tank/



# How to setup nginx server and deploy a new react app *foobar* as example：
- 1. 在cloudflare创建新的DNS
- 2. 在nginx server， 生成https key。 命令是
   `sudo certbot certonly --nginx -d foobar.jackspark.top`
- 3. 通过scp， 把本地打包好的dist目录，放到nginx server 的目录 `/var/www/html/foobar-root`
- 4. 参考 `etc/nginx/sites-available/foobar-subdomain` , 准备好foobar的nginx配置文件 `/etc/nginx/sites-available/foobar-subdomain`， 保存到 nginx server 的   `/home/ubuntu/jackspark.top.server/etc/nginx/sites-available/foobar-subdomain`。 可以通过 git push/pull， 或者scp 到remote server.
- 5. 在nginx server,  把  `/etc/nginx/sites-available`, 创建soft link `foobar-subdomain` 指向到
   `/home/ubuntu/jackspark.top.server/etc/nginx/sites-available/foobar-subdomain`
- 6. 在nginx server, `/etc/nginx/sites-enabled`目录下，创建soft link `foobar-subdomain` 到 `/etc/nginx/sites-available/foobar-subdomain`
- 7. `sudo systemctl restart nginx`
## note：
### sudo certbot certificates 这个命令会列出所有由 Certbot 管理的证书
### nginx server的 alias name是lightsail， 本地ssh时，用 ssh lightsail 即可
### 4,5,6 步其实是做sites-enabled---soft_link--->sites-available---soft_link--->/home/ubuntu/jackspark.top.server/etc/nginx/sites-available/foobar-subdomain(real file config)


# How to setup nginx server and deploy a new nextjs app *foobar* as example：
- 1. 在cloudflare创建新的DNS
- 2. 在nginx server， 生成https key。 命令是
   `sudo certbot certonly --nginx -d foobar.jackspark.top`
- 3. 通过scp， 把本地打包好的.next目录，放到nginx server 的目录 `/var/www/html/foobar-root`

- 4. 参考 `/etc/nginx/sites-available/foobar-subdomain` , 准备好foobar的nginx配置文件 `/etc/nginx/sites-available/foobar-subdomain`， 保存到 nginx server 的   `/home/ubuntu/jackspark.top.server/etc/nginx/sites-available/foobar-subdomain`。 可以通过 git push/pull， 或者scp 到remote server.

- 5. 在nginx server,  把  `/etc/nginx/sites-available`, 创建soft link `foobar-subdomain`指向到
   `/home/ubuntu/jackspark.top.server/etc/nginx/sites-available/foobar-subdomain`
- 6. 在nginx server, `/etc/nginx/sites-enabled`目录下，创建soft link `foobar-subdomain` 到 `/etc/nginx/sites-available/foobar-subdomain`

- 7. pm2 start server.js --name "foo-bar" 把这个服务deploy 到3000端口， 然后把subdomain映射到本地的3000 端口， 参见guess-subdomain
- 8. `sudo systemctl restart nginx`
## note：
## 停止旧pm2服务
### pm2 delete drawing-guessing
## 重启所有pm2服务
### pm2 restart all
### nginx server的 alias name是lightsail， 本地ssh时，用 ssh lightsail 即可
## 4,5,6 步其实是做sites-enabled---soft_link--->sites-available---soft_link--->/home/ubuntu/jackspark.top.server/etc/nginx/sites-available/foobar-subdomain(real file config)



# How to setup nginx server and deploy a html + js webpage *foobar* as example：
1. 复制文件到 var/www/html/foobar 下
   sudo cp -r  ~/jackspark.top.server/var/www/html/foobar /var/www/html/foobar
2. 在etc/nginx/nginx.conf 下添加 foobar的入口
   sudo cp  ~/jackspark.top.server/etc/nginx/nginx.conf /etc/nginx/nginx.conf 
## note： 参见tank 

# How to renew ssh key which are published by lets encrypt
当 AWS Lightsail 源站 SSL 证书过期导致 Cloudflare 报 Error 526 时，需通过以下步骤更新证书。
准备工作：检查与调整网络连接
Let's Encrypt 的 HTTP 验证（ACME Challenge）需要通过 80 端口 直连源站。
1. 检查 AWS Lightsail 防火墙
 登录 AWS Lightsail 控制台。
 进入对应的服务器实例 \rightarrow 选择 Networking（网络） 页签。
 在 IPv4 Firewall（防火墙） 区域，确认已添加 HTTP (Port 80) 规则，且源 IP 范围为 0.0.0.0/0。
2. 切换 Cloudflare DNS 状态（避开 522 拦截）
 登录 Cloudflare Dashboard，进入目标域名。
 进入 DNS \rightarrow Records。
3. 将待续期的域名（如主域名 @、www 及其他子域名）的代理状态从 Proxied（小黄云） 临时切换为 DNS only（小灰云）。
执行证书续期
在本地终端运行以下命令，跳过 Certbot 的随机延迟并强制续期：
## 1. 强制续期证书并跳过随机等待
ssh lightsail "sudo certbot renew --force-renewal --no-random-sleep-on-renew"

## 2. 重载 Nginx 服务使新证书生效
ssh lightsail "sudo systemctl reload nginx"

4. 恢复代理与验证
恢复 Cloudflare 代理
• 续期成功后，回到 Cloudflare DNS 页面，将之前切换的域名重新改回 Proxied（小黄云），恢复 CDN 与安全防护。
检查证书状态
## 验证源站证书到期时间
ssh lightsail "sudo certbot certificates"

