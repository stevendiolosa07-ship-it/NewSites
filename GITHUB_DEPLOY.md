# Deploy NewSites.com to GitHub Pages
## Free forever. Custom domain. SSL included. 5 minutes.

---

## STEP 1 — Create a free GitHub account
1. Go to **github.com**
2. Click "Sign up" — use your email, create a username and password
3. Verify your email

---

## STEP 2 — Create a new repository
1. Once logged in, click the **"+"** icon (top right) → "New repository"
2. Name it exactly: **newsites** (or anything you want)
3. Set it to **Public** (required for free GitHub Pages)
4. Check "Add a README file"
5. Click **"Create repository"**

---

## STEP 3 — Upload your app.html file
1. Inside your new repo, click **"Add file"** → **"Upload files"**
2. Drag and drop your **app.html** file
3. **IMPORTANT**: Rename it to **index.html** before uploading
   (GitHub Pages serves index.html as the homepage automatically)
4. Scroll down, click **"Commit changes"**

---

## STEP 4 — Enable GitHub Pages
1. Click **"Settings"** tab (top of your repo)
2. Scroll down to **"Pages"** in the left sidebar
3. Under "Source" → select **"Deploy from a branch"**
4. Branch: select **"main"** → folder: **"/ (root)"**
5. Click **"Save"**
6. Wait 2-3 minutes, then refresh the page
7. You'll see: **"Your site is live at https://yourusername.github.io/newsites"**

---

## STEP 5 — Connect your custom domain (optional)
1. Buy your domain from namecheap.com (e.g. NewSitesAI.com ~$12/yr)
2. In GitHub Pages settings → "Custom domain" → type your domain → Save
3. Go to Namecheap → Manage your domain → Advanced DNS
4. Add these 4 "A Records" pointing to GitHub:
   - 185.199.108.153
   - 185.199.109.153
   - 185.199.110.153
   - 185.199.111.153
5. Add a CNAME record: www → yourusername.github.io
6. Wait 10-30 min for DNS. GitHub auto-adds free SSL.

---

## TO UPDATE YOUR SITE LATER
1. Go to your repo on github.com
2. Click on index.html → click the pencil icon (edit)
3. Paste your new code → "Commit changes"
4. Site updates in ~60 seconds

Or drag a new index.html file using "Upload files" to replace it.

---

## YOUR LIVE URLS
- Free URL: https://yourusername.github.io/newsites
- Custom domain (after step 5): https://yourcustomdomain.com
