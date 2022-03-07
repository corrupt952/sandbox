FROM node:16-bullseye

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

ENV APP_PATH /app
WORKDIR $APP_PATH

CMD ["yarn", "dev"]
