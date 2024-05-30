// Get NUI message

let YTPlayers = {};

function onYouTubeIframeAPIReady() {

}

function onPlayerStateChange(event) {
    if (event.data == YT.PlayerState.ENDED) {
        // Video has finished playing
        //console.log('Video finished');
		//console.log(event.target.getVideoData().video_id);
        // You can perform additional actions here
    }
}

function onPlayerReadyPromise() {
	return new Promise((resolve) => {
		window.onPlayerReadyResolve = resolve;
	});
}
function onPlayerReady(event) {
	//event.target.playVideo();
	//window.onPlayerReadyResolve();
	window.onPlayerReadyResolve?.();
}

async function PlayVideoWithID(vidSourceID, videoID) {
	if (!(vidSourceID in YTPlayers)) {
		allocateNewPlayer(vidSourceID);
		//console.log('Waiting for player to be ready');
		await onPlayerReadyPromise(); // We have to wait until the player is ready otherwise the video won't play
	}
	YTPlayers[vidSourceID].loadVideoById(videoID);

	// We have to wait until the video is loaded otherwise the video won't play
	new Promise((resolve) => {
		let interval = setInterval(() => {
			// Cued, playing or paused
			if (YTPlayers[vidSourceID].getPlayerState() == 5 || YTPlayers[vidSourceID].getPlayerState() == 1 || YTPlayers[vidSourceID].getPlayerState() == 2) {
				clearInterval(interval);
				resolve();
			}
		}, 1000);
	});

	YTPlayers[vidSourceID].unMute();
	YTPlayers[vidSourceID].playVideo();
}

function UpdateVideoData(vidSourceID, videoData) {
	if (vidSourceID in YTPlayers) {
		if (YTPlayers[vidSourceID].getVideoUrl?.() == undefined) {
			return;
		}

		// Update Video if it's different
		if (videoData.videoUrl == YoutubeTools.GetYouTubeVideoId(YTPlayers[vidSourceID].getVideoUrl())) {
		} else {
			YTPlayers[vidSourceID].cueVideoById(videoData.videoUrl);
		}

		//console.log(JSON.stringify(videoData));

		// Check if video is finished
		//if (videoData.videoCurrentTime > videoData.videoDuration) {
		//	YTPlayers[vidSourceID].pauseVideo();
		//	return;
		//}

		// Update Video Status if it's different
		if (YTPlayers[vidSourceID].getPlayerState() != videoData.videoState) {
			if (videoData.videoState == 1) {
				YTPlayers[vidSourceID].playVideo();
				YTPlayers[vidSourceID].seekTo(videoData.videoCurrentTime);
				if (videoData.videoLoaded == false) {
					$.post('https://' + Config.ResourceFolderName + '/SetVideoLoaded', JSON.stringify({ vidSrcID: vidSourceID, vidLoaded: true }));
				}
			} else if (videoData.videoState == 2) {
				YTPlayers[vidSourceID].pauseVideo();
				YTPlayers[vidSourceID].seekTo(videoData.videoCurrentTime);
			} else if (videoData.videoState == 0) {
				YTPlayers[vidSourceID].stopVideo();
			}
		}

		// Update Video Time if it's too different
		if (videoData.videoState != 0 && Math.abs(YTPlayers[vidSourceID].getCurrentTime() - videoData.videoCurrentTime) > 5) {
			YTPlayers[vidSourceID].seekTo(videoData.videoCurrentTime);
		}

		// Update Video Volume if it's different
		//if (YTPlayers[vidSourceID].getVolume() != videoData.videoVolume) {
			YTPlayers[vidSourceID].setVolume(videoData.videoVolume);
		//}

		//YTPlayers[vidSourceID].seekTo(videoData.sec);
	} else {
		allocateNewPlayer(vidSourceID);
	}
}

// SourceID format: playerid-1, playerid-2, playerid-3, etc.
function allocateNewPlayer(vidSourceID) {
	// Find div with id "mainpage" and create a new div element inside it
	var mainpageDiv = document.getElementById('mainpage');
	var playerDiv = document.createElement('div');
	mainpageDiv.appendChild(playerDiv);
	//playerDiv.id = 'YTPlayer-' + YTPlayers.length;
	playerDiv.id = 'YTPlayer-' + vidSourceID;

	player = new YT.Player(playerDiv.id, {
		height: '0',
		width: '0',
		//videoId: 'v7UF4KJJ1-o?autoplay=1',
		videoId: '',
		playerVars: {
			'autoplay': 0, // Set autoplay to 1 to enable autoplay
			'suggestedQuality': 'medium'
		},
		events: {
			'onStateChange': onPlayerStateChange,
			'onReady': onPlayerReady,
		},
	});

	YTPlayers[vidSourceID] = player;
}

$(document).ready(function(){
    window.addEventListener('message', async function(event) {
        switch(event.data.action) {
			/*
            case 'SetURL':
				player.loadVideoById(event.data.url);
				break;
			case 'SetSec':
				player.seekTo(event.data.sec);
				break;
			*/
			case 'GetVideoDataFromID':
				let dataToSend = await GetVideoDataFromID(event.data.vidSourceID, event.data.videoID);
				$.post('https://' + Config.ResourceFolderName + '/ReceiveVideoData', JSON.stringify(dataToSend));
				break;
			case 'PlayVideoWithID':
				PlayVideoWithID(event.data.vidSourceID, event.data.videoID);
				break;
			case 'UpdateVideoData':
				UpdateVideoData(event.data.videoSourceID, event.data.videoData);
				break;
			//case  
		}
	})
});

const GetVideoDataFromID = async (vidSourceID, videoID) => {
	//if (YTPlayers[vidSourceID] !== undefined) {
	if (!(vidSourceID in YTPlayers)) {
		allocateNewPlayer(vidSourceID);
		await onPlayerReadyPromise(); // We have to wait until the player is ready otherwise the video won't play
	}
	// Wrap the $.getJSON call in a promise to wait for its completion
    const videoData = await new Promise((resolve, reject) => {
        $.getJSON('https://noembed.com/embed', {format: 'json', url: 'https://www.youtube.com/watch?v=' + videoID }, function (data) {
            resolve(data);
        });
    });

    YTPlayers[vidSourceID].loadVideoById(videoID);
	YTPlayers[vidSourceID].mute(); // Just in case, player shouldn't hear this

	// We have to wait until the video is loaded otherwise the video won't play
	await new Promise((resolve) => {
		let interval = setInterval(() => {
			// Cued, playing or paused
			if (YTPlayers[vidSourceID].getPlayerState() == 5 || YTPlayers[vidSourceID].getPlayerState() == 1 || YTPlayers[vidSourceID].getPlayerState() == 2) {
				clearInterval(interval);
				resolve();
			}
		}, 1000);
	});

    let videoDuration = YTPlayers[vidSourceID].getDuration();
	YTPlayers[vidSourceID].pauseVideo();
	YTPlayers[vidSourceID].unMute();
    let videoTitle = videoData.title;
    let videoChannel = videoData.author_name.replace(' - Topic', '');

    return {
        url: videoID,
        title: videoTitle,
        author: videoChannel,
        duration: videoDuration,
        vidSourceID: vidSourceID
    };
}
