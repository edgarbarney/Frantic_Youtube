CREATE TABLE IF NOT EXISTS `frantic_youtube_citizens` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `citizenid` varchar(50) NOT NULL,
  `playlists` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL COMMENT 'Playlists (JSON array)',
  `videos` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL COMMENT 'Played Songs (Except Playlist Songs, JSON array)',
  PRIMARY KEY (`id`),
  UNIQUE KEY `citizenid` (`citizenid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_general_ci;

-- Migration for databases created with the old schema. Run once.
-- TEXT holds at most 64 KB, which a long history or playlist overflows, truncating the JSON.
-- If the unique key fails, remove duplicate citizenid rows first (the old code could insert one per concurrent request).
--
-- ALTER TABLE `frantic_youtube_citizens`
--   MODIFY `citizenid` varchar(50) NOT NULL,
--   MODIFY `playlists` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL COMMENT 'Playlists (JSON array)',
--   MODIFY `videos` mediumtext CHARACTER SET utf8mb4 COLLATE utf8mb4_bin DEFAULT NULL COMMENT 'Played Songs (Except Playlist Songs, JSON array)',
--   ADD UNIQUE KEY `citizenid` (`citizenid`);
