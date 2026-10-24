fx_version "cerulean"
lua54 'yes'
game 'gta5'

description "A Server Assisted Youtube Sound Playing Library"
author "FranticDreamer"


ui_page 'html/index.html'

shared_script {
	"config.lua",
	"shared/debug.lua",
}

client_script {
	"client/client.lua",
}

server_script {
	"@oxmysql/lib/MySQL.lua",
	"server/server.lua",
}

files {
	'html/index.html',
	'html/js/*.js',
}

dependencies {
	'oxmysql',
}

--escrow_ignore {
--	'Config.lua',
--}
