# ddev-project-extend

## Current Sprint
- [ ] [FEAT] dpx new: добавить флаг --here (или интерактивный выбор) для инициализации DDEV в текущей директории <!-- id: 1ke93lfm -->
  * Note (2026-11-15 07:11 UTC): Сейчас dpx new всегда жестко создает проект по дефолтному пути ~/projects/work/php/. Это ломает сценарий, когда нужно настроить DDEV для уже существующего проекта (например, boiler-vite-agent с папкой backend). Решение: если передан флаг --here или выбрана опция 'Current directory', использовать pwd вместо дефолтного пути.
- [ ] [BUG] refresh: не подхватывает конкретную БД из wp-config.php <!-- id: ppe0qbmf -->
- [ ] [NOT TESTED] CMS Support: Joomla и OpenCart <!-- id: xexioper -->
- [ ] [DEFERRED] logging: критические ошибки только в консоль <!-- id: u4eou515 -->
