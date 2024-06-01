fx_version "cerulean"
lua54 'yes'
game 'gta5'

description "A Server Assisted Youtube Sound Playing Library"
author "FranticDreamer"


ui_page 'html/index.html'

client_script {
	"client/client.lua",
}
server_script {
	"server/server.lua",
	"@oxmysql/lib/MySQL.lua",
}

shared_script {
	"config.lua",
}

files {
	'html/index.html',
	'html/js/*.js',
	'html/js/plugins/*.js',
	'html/css/*.css',
}

dependencies {
	'oxmysql',
}

--escrow_ignore {
--	'Config.lua',
--}
