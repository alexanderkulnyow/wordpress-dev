### Developing Docker image for WordPress Dev Env with:

* Xdebug
* php ext optimized
* wp-cli
* composer

[DockerHub: alexanderkulnyow/wordpress-dev](https://hub.docker.com/repository/docker/alexanderkulnyow/wordpress-dev/general)

```bash
docker push alexanderkulnyow/wordpress-dev:latest
```

docker-compose.yaml

```yaml 
networks:
	wp-network:
		name: ${PROJECT_NAME}-network

volumes:
	wp-data:
		name: ${PROJECT_NAME}-data
			
services:
	database:
		image: mariadb:10.11
		volumes:
			- .docker/dbData:/var/lib/mysql
		ports:
			- "3306:3306"
		environment:
			MARIADB_DATABASE: ${WORDPRESS_DB_NAME}
			MARIADB_USER: ${WORDPRESS_DB_USER}
			MARIADB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
			MARIADB_RANDOM_ROOT_PASSWORD: 1
		networks:
			- wp-dev-network

	wordpress:
		depends_on:
			- database
		image: alexanderkulnyow/wordpress-dev:latest
		container_name: "${PROJECT_NAME}-container"
		ports:
			- "${WORDPRESS_PORT}:80"
			- "9003:9003" #is deve
		environment:
			WORDPRESS_DB_HOST: ${WORDPRESS_DB_HOST}
			WORDPRESS_DB_USER: ${WORDPRESS_DB_USER}
			WORDPRESS_DB_PASSWORD: ${WORDPRESS_DB_PASSWORD}
			WORDPRESS_DB_NAME: ${WORDPRESS_DB_NAME}
			WORDPRESS_TABLE_PREFIX: ${WORDPRESS_TABLE_PREFIX}
			XDEBUG: ${XDEBUG:-false} #is deve - true
		volumes:
			- wp-dev-data:/var/www/html/
			- ./var/log:/var/log/apache2
		extra_hosts:
			- "host.docker.internal:host-gateway"
		networks:
			- wp-dev-network

```

### .env example

```dotenv
PROJECT_NAME=wordpress-dev
ENABLE_XDEBUG=true
###> wordpress ###
WORDPRESS_PORT=8080
WORDPRESS_DB_HOST=database
WORDPRESS_DB_NAME=database
WORDPRESS_DB_USER=user
WORDPRESS_DB_PASSWORD=password
WORDPRESS_TABLE_PREFIX=wp_

```

**php.d** - dir with *.ini extenshions \
**wp-cli** - dir with wp-cli scripts
