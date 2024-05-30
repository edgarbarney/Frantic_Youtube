// Edited version of https://gist.github.com/pinceladasdaweb/6662290

var YoutubeThumbs = (function () {
    'use strict';

    var video, results;

    var getThumb = function (url, size) {
        if (url === null) {
            return '';
        }
        size    = (size === null) ? 'big' : size;
        results = url.match('[\\?&]v=([^&#]*)');
        video   = (results === null) ? url : results[1];

        //if (size === 'small') {
        //    return 'http://img.youtube.com/vi/' + video + '/2.jpg';
        //}
        //return 'http://img.youtube.com/vi/' + video + '/0.jpg';

        if (size === 'small') {
            return 'http://i.ytimg.com/vi/' + video + '/2.jpg';
        }
        return 'http://img.youtube.com/vi/' + video + '/maxresdefault.jpg';
    };

    return {
        GetThumb: getThumb
    };
}());

//Example of usage:
//var thumb = YoutubeThumbs.GetThumb('http://www.youtube.com/watch?v=F4rBAf1wbq4', 'small');
//console.log(thumb);