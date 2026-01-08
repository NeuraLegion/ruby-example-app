FROM ruby:2.3

RUN sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g' /etc/apt/sources.list \
  && sed -i 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' /etc/apt/sources.list \
  && sed -i '/stretch-updates/d' /etc/apt/sources.list \
  && apt-get -o Acquire::Check-Valid-Until=false -o Acquire::AllowInsecureRepositories=true update \
  && apt-get install -y --no-install-recommends --allow-unauthenticated \
    build-essential \
    libpq-dev \
    nodejs \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY Gemfile Gemfile.lock ./
RUN gem install bundler -v 1.10.6 \
  && bundle install

COPY . .

EXPOSE 3000

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
