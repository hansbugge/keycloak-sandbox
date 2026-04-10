FROM node:20-alpine

WORKDIR /app

# Install dependencies first (layer cache friendly)
COPY package.json ./
RUN npm install --omit=dev

COPY app.js ./

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=5s --retries=5 --start-period=10s \
  CMD wget -q -O /dev/null http://localhost:3000/health || exit 1

CMD ["node", "app.js"]
