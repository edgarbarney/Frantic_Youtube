YoutubeTools = {};

YoutubeTools.GetVideoDuration = function(videoId) {
    // TODO: Implement the function to get the video duration
    // For now, we're using the youtube player in the main.js
    return 1200; // 20 minutes
}


YoutubeTools.GetYouTubeVideoId = function(url) {
    if (url == null || url == undefined){
        return null;
    }

    // Regular expressions to match different forms of YouTube URLs
    var regExp = /^.*(youtu\.be\/|v\/|u\/\w\/|embed\/|watch\?v=|\&v=)([^#\&\?]*).*/;
    var match = url.match(regExp);

    // If the URL matches one of the patterns, return the video ID
    if (match && match[2].length === 11) {
        return match[2];
    } else {
        // If no match is found, return null or handle the error accordingly
        return null;
    }
}

//YoutubeTools.GetVideoDuration(videoId)
//    .then(duration => {
//        console.log('Duration:', duration, 'seconds');
//})
//    .catch(error => {
//        console.error('Error:', error);
//});
  