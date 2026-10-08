import CoreGraphics

/// 팝오버와 "아이콘이 숨겨졌을 때" 패널, 개발용 스냅샷이 함께 쓰는 크기. 한 곳에 둬서 서로 어긋나지 않게 한다.
public enum PopoverMetrics {
    /// 행마다 버튼 4개와 상태칩·시간이 항상 붙으므로, 제목이 쓸 자리를 확보하려고 넓게 잡는다(프로젝트 태그는 둘째 줄).
    public static let width: CGFloat = 560
    public static let height: CGFloat = 520
}
