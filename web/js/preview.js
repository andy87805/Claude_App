// 預覽：點完成的檔案，全螢幕看照片、播影片、看 PDF；可以切換「結果／原檔」比較，也能左右切換檔案。

const TYPE_LABELS = {
  'image/jpeg': 'JPG', 'image/png': 'PNG', 'image/webp': 'WebP', 'image/gif': 'GIF',
  'image/heic': 'HEIC', 'image/heif': 'HEIF', 'image/avif': 'AVIF',
  'video/mp4': 'MP4', 'video/quicktime': 'MOV', 'video/webm': 'WebM', 'application/pdf': 'PDF',
};

function kindOf(file) {
  const t = file.type || '';
  if (t === 'application/pdf' || /\.pdf$/i.test(file.name)) return 'pdf';
  if (t.startsWith('video/') || /\.(mp4|m4v|mov|webm|mkv)$/i.test(file.name)) return 'video';
  return 'image';
}

function typeLabel(file) {
  return TYPE_LABELS[file.type] || (file.name.match(/\.([^.]+)$/)?.[1] || '').toUpperCase();
}

/**
 * @param {{getItems:()=>any[], formatBytes:(n:number)=>string, canShare:(f:File[])=>boolean,
 *          shareFiles:(f:File[])=>Promise<void>, triggerDownload:(url:string,name:string)=>void,
 *          reduceMotion:()=>boolean}} deps
 */
export function createPreview(deps) {
  const dialog = document.querySelector('#preview');
  const $ = (sel) => dialog.querySelector(sel);
  const stage = $('.pv-stage');
  const toggle = $('.pv-toggle');

  let list = [];
  let index = 0;
  let view = 'result';
  let token = { cancelled: true };
  let tempUrls = [];

  const current = () => list[index];

  function cleanupStage() {
    token.cancelled = true;
    stage.querySelectorAll('video').forEach((v) => {
      v.pause();
      v.removeAttribute('src');
      v.load();
    });
    stage.replaceChildren();
    stage.classList.remove('zoomed', 'pdf');
    tempUrls.forEach((u) => URL.revokeObjectURL(u));
    tempUrls = [];
  }

  function urlFor(item, which) {
    if (which === 'result') return item.result.url;
    if (item.thumbUrl) return item.thumbUrl; // 照片原檔已經有網址
    const url = URL.createObjectURL(item.file);
    tempUrls.push(url);
    return url;
  }

  function showMessage(text) {
    const p = document.createElement('p');
    p.className = 'pv-message';
    p.textContent = text;
    stage.replaceChildren(p);
  }

  function setInfo(file, extra = '') {
    const item = current();
    $('.pv-name').textContent = file.name;
    const parts = [typeLabel(file), deps.formatBytes(file.size)];
    if (extra) parts.splice(1, 0, extra);
    let line = parts.filter(Boolean).join(' · ');
    if (view === 'result' && !item.result.kept && item.file.size) {
      const pct = Math.round((1 - item.result.file.size / item.file.size) * 100);
      if (pct > 0) line += `（原檔 ${deps.formatBytes(item.file.size)}，小了 ${pct}%）`;
    }
    $('.pv-sub').textContent = line;
  }

  async function render() {
    cleanupStage();
    const item = current();
    const file = view === 'result' ? item.result.file : item.file;
    const kind = kindOf(file);
    const url = urlFor(item, view);
    token = { cancelled: false };
    const myToken = token;

    $('.pv-count').textContent = list.length > 1 ? `${index + 1} / ${list.length}` : '';
    $('.pv-prev').hidden = list.length < 2;
    $('.pv-next').hidden = list.length < 2;
    // 保留原檔的項目沒有「結果」可以比較
    toggle.hidden = !!item.result.kept;
    toggle.style.setProperty('--i', view === 'result' ? 0 : 1);
    toggle.querySelectorAll('button').forEach((b) => b.setAttribute('aria-checked', String(b.dataset.view === view)));
    setInfo(file);
    stage.dataset.kind = kind;

    if (kind === 'image') {
      const img = document.createElement('img');
      img.className = 'pv-image';
      img.alt = file.name;
      img.addEventListener('load', () => {
        if (!myToken.cancelled) setInfo(file, `${img.naturalWidth} × ${img.naturalHeight}`);
      });
      img.addEventListener('error', () => showMessage('這個瀏覽器無法預覽這種格式'));
      img.addEventListener('click', (e) => toggleZoom(img, e));
      img.src = url;
      stage.append(img);
    } else if (kind === 'video') {
      const video = document.createElement('video');
      video.className = 'pv-video';
      video.controls = true;
      video.playsInline = true;
      video.preload = 'metadata';
      video.addEventListener('loadedmetadata', () => {
        if (myToken.cancelled) return;
        const secs = Math.round(video.duration);
        const time = Number.isFinite(secs) ? `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}` : '';
        setInfo(file, [video.videoWidth && `${video.videoWidth} × ${video.videoHeight}`, time].filter(Boolean).join(' · '));
      });
      video.addEventListener('error', () => showMessage('這個瀏覽器無法播放這種影片格式'));
      video.src = url;
      stage.append(video);
    } else {
      stage.classList.add('pdf');
      const pages = document.createElement('div');
      pages.className = 'pv-pages';
      const loading = document.createElement('p');
      loading.className = 'pv-message';
      loading.textContent = '正在載入 PDF…';
      stage.append(loading, pages);
      try {
        const { renderPdfPreview } = await import('./pdf.js');
        const count = await renderPdfPreview(file, pages, myToken);
        if (!myToken.cancelled) {
          loading.remove();
          setInfo(file, `${count} 頁`);
        }
      } catch (err) {
        if (!myToken.cancelled) showMessage(`無法預覽這個 PDF：${err.message || err}`);
      }
    }
  }

  function toggleZoom(img, event) {
    if (stage.classList.contains('zoomed')) {
      stage.classList.remove('zoomed');
      img.style.width = '';
      return;
    }
    const rect = img.getBoundingClientRect();
    const fx = (event.clientX - rect.left) / rect.width;
    const fy = (event.clientY - rect.top) / rect.height;
    const width = Math.max(rect.width * 2.5, img.naturalWidth / (window.devicePixelRatio || 1));
    stage.classList.add('zoomed');
    img.style.width = `${width}px`;
    // 放大後讓點的位置留在畫面中間
    requestAnimationFrame(() => {
      stage.scrollLeft = img.offsetWidth * fx - stage.clientWidth / 2;
      stage.scrollTop = img.offsetHeight * fy - stage.clientHeight / 2;
    });
  }

  function go(step) {
    if (list.length < 2) return;
    index = (index + step + list.length) % list.length;
    view = 'result';
    stage.classList.remove('slide-left', 'slide-right');
    void stage.offsetWidth;
    stage.classList.add(step > 0 ? 'slide-left' : 'slide-right');
    render();
  }

  async function close() {
    if (!dialog.open) return;
    if (!deps.reduceMotion()) {
      dialog.classList.add('closing');
      await new Promise((r) => setTimeout(r, 200));
    }
    dialog.classList.remove('closing');
    dialog.close();
  }

  dialog.addEventListener('close', () => {
    cleanupStage();
    document.documentElement.classList.remove('pv-open');
  });
  dialog.addEventListener('cancel', (e) => {
    e.preventDefault(); // 用自己的關閉動畫
    close();
  });
  dialog.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowRight') go(1);
    if (e.key === 'ArrowLeft') go(-1);
  });
  $('.pv-close').addEventListener('click', close);
  $('.pv-prev').addEventListener('click', () => go(-1));
  $('.pv-next').addEventListener('click', () => go(1));
  toggle.querySelectorAll('button').forEach((b) =>
    b.addEventListener('click', () => {
      if (view === b.dataset.view) return;
      view = b.dataset.view;
      render();
    }),
  );
  $('.pv-save').addEventListener('click', () => deps.shareFiles([current().result.file]));
  $('.pv-download').addEventListener('click', () => deps.triggerDownload(current().result.url, current().result.file.name));

  // 左右滑動切換檔案（放大或看 PDF 時不切換，避免和捲動衝突）
  let touch = null;
  stage.addEventListener('touchstart', (e) => {
    touch = e.touches.length === 1 ? { x: e.touches[0].clientX, y: e.touches[0].clientY } : null;
  }, { passive: true });
  stage.addEventListener('touchend', (e) => {
    if (!touch || stage.classList.contains('zoomed') || stage.classList.contains('pdf')) return;
    const dx = e.changedTouches[0].clientX - touch.x;
    const dy = e.changedTouches[0].clientY - touch.y;
    if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy) * 1.5) go(dx < 0 ? 1 : -1);
    touch = null;
  }, { passive: true });

  return {
    open(item) {
      list = deps.getItems().filter((i) => i.status === 'done');
      index = Math.max(0, list.indexOf(item));
      view = 'result';
      $('.pv-save').hidden = !deps.canShare([item.result.file]);
      document.documentElement.classList.add('pv-open');
      dialog.showModal();
      render();
    },
    close,
  };
}
